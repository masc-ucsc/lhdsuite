#!/usr/bin/env python3
"""Flatten one Ibex checkout into a single .sv for `lhd formal verify`.

Starts at --top, pulls in every module and package it uses (found by name),
inlines `include files, and defines FPV_ON so the built-in `ASSERT macros
become plain `assert property` (and ASSERT_KNOWN / $isunknown drop out).
Usage: flatten.py SRC_DIR --top ibex_core -o out.sv
"""
import argparse, pathlib, re, sys

# Search order, newest layout first; older Ibex kept files in the later entries.
SEARCH = ["rtl", "rtl/include", "shared/rtl", "vendor/lowrisc_ip/ip/prim/rtl", "vendor/lowrisc_ip/ip/prim_generic/rtl",
          "vendor/lowrisc_ip/prim/rtl", "vendor/lowrisc_ip/prim_generic/rtl", "vendor/lowrisc_ip/dv/sv/dv_utils", "dv/fcov"]
# Macro headers some old files use without including them: inlined once at the top.
PRELUDE = ["prim_assert.sv", "dv_fcov_macros.svh"]
# X-checks mean nothing in a two-valued model; newer Ibex drops them under FPV_ON, older Ibex did not.
NO_X_CHECKS = """`undef ASSERT_KNOWN
`define ASSERT_KNOWN(__name, __sig, __clk = `ASSERT_DEFAULT_CLK, __rst = `ASSERT_DEFAULT_RST)
`undef ASSERT_KNOWN_IF
`define ASSERT_KNOWN_IF(__name, __sig, __enable, __clk = `ASSERT_DEFAULT_CLK, __rst = `ASSERT_DEFAULT_RST)
"""
# 2019 Ibex expected the integrator to supply the clock gate; formal stand-in, used only if none is found.
CLOCK_GATE = """module prim_clock_gating (input logic clk_i, input logic en_i, input logic test_en_i, output logic clk_o);
  assign clk_o = clk_i;  // formal stand-in: clock always on
endmodule
"""
DEFINES = ["FPV_ON", "FORMAL"]
COMMENT = re.compile(r"//[^\n]*|/\*.*?\*/", re.S)
MODULE = re.compile(r"^\s*module\s+(\w+)", re.M)
PACKAGE = re.compile(r"^\s*package\s+(\w+)", re.M)
INST = re.compile(r"\b(\w+)\s*(?:#\s*\(|\s+\w+\s*\()")
PKGREF = re.compile(r"\b(\w+)::")
INCLUDE = re.compile(r'^\s*`include\s+"([^"]+)"[^\n]*$', re.M)


def index(src):
    """Map module/package name -> file, and include name -> file (first dir wins)."""
    mods, pkgs, incs = {}, {}, {}
    for d in SEARCH:
        for f in sorted((src / d).glob("*.sv*")) if (src / d).is_dir() else []:
            incs.setdefault(f.name, f)
            text = COMMENT.sub("", f.read_text(errors="replace"))
            for m in MODULE.findall(text):
                mods.setdefault(m, f)
            for p in PACKAGE.findall(text):
                pkgs.setdefault(p, f)
    return mods, pkgs, incs


def inline(path, incs, seen):
    """File text with `include lines replaced by the file (each header once)."""
    def sub(m):
        name = m.group(1)
        if name in seen or name not in incs:
            return f"// include {name} (inlined above)" if name in seen else m.group(0)
        seen.add(name)
        return inline(incs[name], incs, seen)
    return INCLUDE.sub(sub, path.read_text(errors="replace"))


DROPPED = []
ISUNKNOWN = re.compile(r"\$isunknown\s*\(")


def two_state(text):
    """$isunknown(x) is always 0 in a two-valued formal model."""
    while (m := ISUNKNOWN.search(text)):
        _, end = split_args(text, m.end() - 1)
        text = text[:m.start()] + "1'b0" + text[end:]
    return text


MACRO = re.compile(r"`(ASSERT|ASSUME)(_IF)?\(")


def split_args(text, i):
    """Split the macro call that opens at text[i] == '('; return (args, end index)."""
    args, depth, start = [], 0, i + 1
    for j in range(i, len(text)):
        c = text[j]
        if c in "({[":
            depth += 1
        elif c in ")}]":
            depth -= 1
            if depth == 0:
                return args + [text[start:j].strip()], j + 1
        elif c == "," and depth == 1:
            args.append(text[start:j].strip())
            start = j + 1
    return None, i


def split_top(prop, op):
    """Split prop at a top-level (not nested) operator."""
    depth = 0
    for j in range(len(prop) - 2):
        depth += prop[j] in "([{"
        depth -= prop[j] in ")]}"
        if depth == 0 and prop[j:j + 3] == op:
            return prop[:j].strip(), prop[j + 3:].strip()
    return None


TRANSLATE_OFF = re.compile(r"//\s*(?:synopsys|pragma|synthesis)\s+translate_off.*?//\s*(?:synopsys|pragma|synthesis)\s+translate_on[^\n]*", re.S)
UNPACKED_ASSIGN = re.compile(r"assign\s+(\w+)\s*=\s*'\{")


def sim_only_and_patterns(text):
    """Drop translate_off regions; split `assign X = '{a, b}` on an unpacked [N] array per element."""
    text = TRANSLATE_OFF.sub("// (translate_off region removed)", text)
    out, pos = [], 0
    for m in UNPACKED_ASSIGN.finditer(text):
        name = m.group(1)
        decl = re.search(rf"\b{name}\s*\[\s*(\d+)\s*\]\s*;", text)  # `logic [..] name [N];`
        if not decl or m.start() < pos:
            continue
        args, end = split_args(text, m.end() - 1)
        if not args or len(args) != int(decl.group(1)):
            continue
        semi = text.index(";", end)
        out += [text[pos:m.start()], " ".join(f"assign {name}[{i}] = {a};" for i, a in enumerate(args))]
        pos = semi + 1
    return "".join(out) + text[pos:]


def rewrite_temporal(text):
    """Lower `|=>` (and ASSERT_IF around an implication) to forms LiveHD reads.

    A |=> B  becomes  a flop q <= A (0 in reset) and the check q |-> B.
    ASSERT_IF(en) with A |-> B inside becomes (en) && (A) |-> B.
    """
    out, pos, n = [], 0, 0
    for m in MACRO.finditer(text):
        if m.start() < pos:
            continue
        args, end = split_args(text, m.end() - 1)
        if not args or args[0].startswith("__") or "`" in args[0]:  # macro definitions stay as they are
            continue
        kind, has_if = m.group(1), m.group(2)
        name, prop = args[0], args[1]
        en = args[2] if has_if else None
        rest = args[3:] if has_if else args[2:]
        clk = rest[0] if len(rest) > 0 else "clk_i"
        rst = rest[1] if len(rest) > 1 else "!rst_ni"
        if re.search(r"##|\[\*|\[->|\[=", prop):  # real sequences: not supported, drop and log
            out += [text[pos:m.start()], f"/* dropped (sequence): {name} */"]
            pos, n = end, n + 1
            DROPPED.append(name)
            continue
        nxt, imp = split_top(prop, "|=>"), split_top(prop, "|->")
        if not nxt and not (en and imp):
            continue
        ante, cons = nxt or imp
        if en:
            ante = f"({en}) && ({ante})"
        pre = ""
        if nxt:
            q = f"__nx_{name}_q"
            pre = f"logic {q}; always_ff @(posedge {clk}) {q} <= ({rst}) ? 1'b0 : ({ante}); "
            ante = q
        out += [text[pos:m.start()], f"{pre}`{kind}({name}, ({ante}) |-> ({cons}), {clk}, {rst})"]
        pos, n = end, n + 1
    return "".join(out) + text[pos:], n


# Ibex's own bus protocol assumptions (dv/formal/check/protocol/mem.sv), per port.
MEM_ASSUME = """
  logic [7:0] {p}_outstanding_q;
  always_ff @(posedge clk_i or negedge rst_ni)
    if (!rst_ni) {p}_outstanding_q <= '0;
    else         {p}_outstanding_q <= {p}_outstanding_q + {p}_gnt_i - {p}_rvalid_i;
  {P}MemValidBounded: assume property (@(posedge clk_i) {p}_outstanding_q == 8'b0 |-> ~{p}_rvalid_i);
  {P}MemGntOnRequest: assume property (@(posedge clk_i) ~{p}_req_o |-> ~{p}_gnt_i);
"""


def active_lines(text):
    """Drop lines inside `ifdef blocks whose macro is not in DEFINES."""
    keep, stack = [], []
    for line in text.splitlines():
        m = re.match(r"\s*`(ifdef|ifndef|elsif|else|endif)\b\s*(\w*)", line)
        if m:
            k, name = m.groups()
            if k in ("ifdef", "ifndef"):
                stack.append((name in DEFINES) == (k == "ifdef"))
            elif k == "else" and stack:
                stack[-1] = not stack[-1]
            elif k == "endif" and stack:
                stack.pop()
            continue
        if all(stack):
            keep.append(line)
    return "\n".join(keep)


def env_wrapper(core_file, top):
    """ibex_env: same header as the core, every port passed through, plus the bus assumptions."""
    text = active_lines(COMMENT.sub("", core_file.read_text(errors="replace")))
    m = re.search(rf"module\s+{top}\b(.*?\)\s*);", text, re.S)
    header = m.group(1)
    # port list = text after the parameter list's closing ") ("
    plist = re.split(r"\)\s*\(", header, maxsplit=1)[-1] if "#" in header else header[header.find("(") + 1:]
    names = re.findall(r"(\w+)\s*(?:\[[^\]]*\]\s*)*(?:,|\)\s*$)", plist.strip())
    conns = ",\n    ".join(f".{n}({n})" for n in names)
    body = "".join(MEM_ASSUME.format(p=p, P=p.capitalize()) for p in ("instr", "data")
                   if f"{p}_gnt_i" in names and f"{p}_rvalid_i" in names)
    return f"module ibex_env{header};\n  {top} u_core (\n    {conns}\n  );\n{body}endmodule\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src", type=pathlib.Path)
    ap.add_argument("--top", default="ibex_core")
    ap.add_argument("-o", "--out", type=pathlib.Path, required=True)
    ap.add_argument("--env", action="store_true", help="add ibex_env: core + Ibex's bus assumptions")
    a = ap.parse_args()
    mods, pkgs, incs = index(a.src.resolve())
    if a.top not in mods:
        sys.exit(f"top {a.top} not found")

    # walk instantiations and package references
    files, pkg_order, todo, done = [], [], [mods[a.top]], set()
    def use_pkg(p):  # depth-first so a package comes after the packages it uses
        if p in done:
            return
        done.add(p)
        for q in sorted(PKGREF.findall(COMMENT.sub("", pkgs[p].read_text(errors="replace")))):
            if q in pkgs and q != p:
                use_pkg(q)
        pkg_order.append(pkgs[p])
    while todo:
        f = todo.pop()
        if f in files:
            continue
        files.append(f)
        text = active_lines(COMMENT.sub("", f.read_text(errors="replace")))  # skip instances under inactive `ifdef
        for p in sorted(set(PKGREF.findall(text)) | set(re.findall(r"import\s+(\w+)\s*::", text))):
            if p in pkgs:
                use_pkg(p)
        for m in sorted(set(INST.findall(text))):
            if m in mods and mods[m] not in files:
                todo.append(mods[m])

    seen, rewrites = set(), 0
    out = [f"`define {d}" for d in DEFINES]
    for h in PRELUDE:
        if h in incs:
            seen.add(h)
            out += [f"// ---- prelude {h}", two_state(inline(incs[h], incs, seen))]
    out.append(NO_X_CHECKS)
    for f in list(dict.fromkeys(pkg_order)) + [f for f in files if f not in pkg_order]:
        text, n = rewrite_temporal(two_state(sim_only_and_patterns(inline(f, incs, seen))))
        out += [f"// ---- {f.relative_to(a.src.resolve())}", text]
        rewrites += n
    if "prim_clock_gating" not in mods and "prim_clock_gating" in "".join(p.read_text(errors="replace") for p in files):
        out += ["// ---- prim_clock_gating (formal stand-in)", CLOCK_GATE]
    if a.env:
        out += ["// ---- ibex_env (generated)", env_wrapper(mods[a.top], a.top)]
    a.out.write_text("\n".join(out) + "\n")
    print(f"{a.out}: {len(pkg_order)} packages, {len(files)} module files, {rewrites} assertions rewritten, dropped: {' '.join(DROPPED) or 'none'}")


if __name__ == "__main__":
    main()
