#!/usr/bin/env python3
"""Emit matched drivers from one schedule; hardware remains in pyrope/ and rtl/."""
from pathlib import Path
import re

HERE = Path(__file__).resolve().parent.parent
STATE = '''  mut hindex:U64 = 0
  mut hwaiting:U64 = 0
  mut left:U64 = 0
  mut beat:U64 = 0
  mut saved_addr:U64 = 0
  mut saved_id:U64 = 0
  mut saved_size:U64 = 0
  mut saved_src:U64 = 0
  mut saved_op:U64 = 0
  mut boot:U64 = 0
  mut landed:U64 = 0
  mut finished:U64 = 0
  mut mdata:U64 = 0
  mut adata:U64 = 0
  mut sum:U64 = 0
'''
BODY = '''    dut.reset = clock < 8
    dut.core_enable = 0
    if hindex >= 8 { dut.core_enable = 0xffff }
    dut.host_req_valid = 0
    if clock >= 8 and hindex < 120 and hwaiting == 0 { dut.host_req_valid = 1 }
    // Host operations 0-7 write the eight Gemmini pointer pairs into accumulator row 60, away from the rows the mesh results fill from row 0. Operations 8-119 drive the TPU
    // while the CPUs run: CTL, REQ, sixteen A/B/D row pushes, then STATUS, the eight result words, four accumulator rows.
    mut haddr:U64 = 0x18f00 + (8 * hindex)
    mut hdata:U64 = finish(id=2 * hindex) | (finish(id=(2 * hindex) + 1) << 32)
    mut hop:U64 = 0
    mut mi:U64 = 0
    if hindex >= 8 { mi = hindex - 8 }
    const mix:U64 = (mi * 2654435761) & 0xffffffff
    if hindex >= 8 {
      hdata = mix | (mix << 32)
      haddr = 0x19000 + (8 * ((mi + 4) % 6))
      if mi == 0 {
        haddr = 0x19038
        hdata = 1
      }
      if mi == 1 {
        haddr = 0x19030
        hdata = 0x4006
      }
      if mi >= 98 {
        hop = 4
        haddr = 0x19040
      }
      if mi >= 99 and mi < 107 { haddr = 0x19080 + (8 * (mi - 99)) }
      if mi >= 107 and mi < 111 { haddr = 0x18000 + (64 * (mi - 107)) }
    }
    dut.host_req_addr = haddr
    dut.host_req_data = hdata
    dut.host_req_meta = (hop << 23) | (3 << 19) | (255 << 2)
    dut.host_rsp_ready = 1
    dut.mem_req_ready = 0
    if left == 0 and hindex >= 8 { dut.mem_req_ready = 1 }
    dut.mem_rsp_valid = 0
    if left != 0 { dut.mem_rsp_valid = 1 }
    mut width:U64 = 4
    if saved_id >= 12 { width = 8 }
    const address:U64 = (saved_addr & (0xffffffff ^ (width - 1))) + (width * beat)
    dut.mem_rsp_data = instruction(addr=address, id=saved_id) | (instruction(addr=address + 4, id=saved_id) << 32)
    dut.mem_rsp_addr = 0
    mut dop:U64 = 1
    if saved_op == 6 { dop = 5 }
    const meta:U64 = (saved_id << 30) | (3 << 27) | (dop << 23) | (saved_size << 19) | (saved_src << 13)
    dut.mem_rsp_meta = meta#[0..=39]
    step
    mut obs:U64 = 0
    if dut.host_req_fire != 0 { hwaiting = 1 }
    if dut.host_rsp_fire != 0 {
      assert(bits(v=dut.seen_host_meta, lo=0, n=1) == 0)
      assert(bits(v=dut.seen_host_meta, lo=35, n=5) == 16)
      assert(bits(v=dut.seen_host_meta, lo=23, n=4) == (hop / 4))
      if hop == 4 { wrap mdata = ((mdata * 31) + bits(v=dut.seen_host_data, lo=0, n=32) + bits(v=dut.seen_host_data, lo=32, n=32)) & 0x7fffffffffffffff }
      if hop == 4 and mi >= 107 and mi < 111 { wrap adata = ((adata * 31) + bits(v=dut.seen_host_data, lo=0, n=32) + bits(v=dut.seen_host_data, lo=32, n=32)) & 0x7fffffffffffffff }
      wrap sum = ((sum * 31) + bits(v=dut.seen_host_data, lo=0, n=32)) & 0x7fffffffffffffff
      wrap sum = ((sum * 31) + bits(v=dut.seen_host_data, lo=32, n=32)) & 0x7fffffffffffffff
      hwaiting = 0
      hindex += 1
      obs = 1
    }
    if dut.mem_rsp_fire != 0 {
      assert(left != 0)
      left -= 1
      beat += 1
      obs = obs | 2
    }
    if dut.mem_req_fire != 0 {
      saved_id = bits(v=dut.seen_mem_meta, lo=35, n=5)
      saved_size = bits(v=dut.seen_mem_meta, lo=19, n=4)
      saved_src = bits(v=dut.seen_mem_meta, lo=13, n=3)
      saved_op = bits(v=dut.seen_mem_meta, lo=23, n=4)
      saved_addr = dut.seen_mem_addr
      const channel:U64 = bits(v=dut.seen_mem_meta, lo=27, n=3)
      assert(saved_id < 16)
      assert(channel == 0 or channel == 4)
      if channel == 0 {
        assert(saved_op == 4 or saved_op == 6)
        assert(saved_size <= 6)
        assert(saved_addr < 0x18000 or saved_addr >= 0x1a000)
        left = 1
        // Size beats using the requester's bus width.
        if saved_id >= 12 { left = (1 << saved_size) / 8 }
        if saved_id < 12 { left = (1 << saved_size) / 4 }
        if left == 0 { left = 1 }
        beat = 0
        mut entry_pc:U64 = 0x10040
        if saved_id >= 12 { entry_pc = 0x10000 }
        if bits(v=saved_addr, lo=6, n=26) == bits(v=entry_pc, lo=6, n=26) { boot = boot | (1 << saved_id) }
        if saved_addr >= 0x10200 and saved_addr < 0x10a00 {
          assert(((1 << saved_id) & 0x5009) != 0)
          assert(((boot >> saved_id) & 1) == 1)
          assert(bits(v=saved_addr, lo=6, n=26) == bits(v=0x10200 + (128 * saved_id), lo=6, n=26))
          landed = landed | (1 << saved_id)
        }
        if saved_addr >= 0x11000 and saved_addr < 0x11800 {
          assert(((1 << saved_id) & 0x5009) != 0)
          assert(((landed >> saved_id) & 1) == 1)
          assert(bits(v=saved_addr, lo=6, n=26) == bits(v=finish(id=saved_id), lo=6, n=26))
          finished = finished | (1 << saved_id)
        }
      }
      obs = obs | (saved_id << 8) | (saved_addr << 16) | (channel << 4)
    }
    wrap sum = ((sum * 31) + obs) & 0x7fffffffffffffff
'''
END = '''  assert(hindex == 120)
  assert(boot == 0xffff)
  assert(landed == 0x5009)
  assert(finished == 0x5009)
  // The accumulator rows the host reads back were written by the mesh results, not by the host: not all zero.
  assert(adata != 0)
  puts("mixed_soc: cycles={cycles} active={finished} sum={sum} mesh={mdata} acc={adata}")
'''


def cpp(src):
    src = re.sub(r'puts\([^\n]*', 'std::printf("mixed_soc: cycles=%llu active=%llu sum=%llu mesh=%llu acc=%llu\\\\n", (unsigned long long)cycles, (unsigned long long)finished, (unsigned long long)sum, (unsigned long long)mdata, (unsigned long long)adata);', src)
    src = re.sub(r'(mut|const) (\w+):U64', lambda m: ('const ' if m[1]=='const' else '')+'uint64_t '+m[2], src)
    src = re.sub(r'\b(?:id|v|lo|n|addr)=', '', src)  # named call arguments only (assignments use spaces)
    src = src.replace('v#[0..=63]', 'v').replace('meta#[0..=39]', '(meta & 0xffffffffffULL)')
    src = src.replace(' and ', ' && ').replace(' or ', ' || ').replace('dut.', 'dut->').replace('clock', 'cycle')
    src = src.replace('wrap ', '')
    src = re.sub(r'if ([^\n{}]+) \{', r'if (\1) {', src)
    lines = []
    for line in src.splitlines():
        if line.strip() == 'step':
            lines.append('    dut->clock = 0; dut->eval(); dut->clock = 1; dut->eval();')
        elif line.strip().startswith('//') or not line.strip(): lines.append(line)
        else:
            line = re.sub(r'(\w+\s*(?:\+=|-=|=)[^{};]+)(?= \})', r'\1;', line)
            if not line.rstrip().endswith(('{','}',';')): line += ';'
            lines.append(line)
    return '\n'.join(lines)


def inline_calls(src):
    # Test blocks currently support builtins, not calls to user comb helpers.
    # Expand the three pure helpers before emitting either language.
    for fn in ['finish', 'bits']:
        while fn + '(' in src:
            at = src.index(fn + '(')
            end = at + len(fn) + 1
            depth = 1
            while depth:
                if src[end] == '(':
                    depth += 1
                elif src[end] == ')':
                    depth -= 1
                end += 1
            args = src[at+len(fn)+1:end-1]
            if fn == 'finish':
                value = '(0x11000 + (128 * (15 - (' + args.split('=',1)[1] + '))))'
            else:
                v, lo, n = args.rsplit(', ',2)
                v = v.split('=',1)[1]
                lo, n = int(lo.split('=')[1]), int(n.split('=')[1])
                value = f'((({v}) >> {lo}) & {(1 << n)-1})'
            src = src[:at] + value + src[end:]
    return src


def instruction_words():
    result = ''
    for k in range(2):
        result += f"""    const pc{k}:U64 = address + {4*k}
    mut ent{k}:U64 = 0x10040
    if saved_id >= 12 {{ ent{k} = 0x10000 }}
    const land{k}:U64 = 0x10200 + (128 * saved_id)
    const imm{k}:U64 = land{k} - ent{k}
    mut word{k}:U64 = 0x13
    if pc{k} == ent{k} {{ word{k} = (((imm{k} >> 20) & 1) << 31) | (((imm{k} >> 1) & 1023) << 21) | (((imm{k} >> 11) & 1) << 20) | (((imm{k} >> 12) & 255) << 12) | 0x6f }}
    const pointer{k}:U64 = 0x18f00 + (4 * saved_id)
    if pc{k} == land{k} {{ word{k} = ((pointer{k} + 0x800) & 0xfffff000) | 0xb7 }}
    if pc{k} == (land{k} + 4) {{ word{k} = ((pointer{k} & 4095) << 20) | 0xa103 }}
    if pc{k} == (land{k} + 8) {{ word{k} = 0x10067 }}
    if pc{k} == finish(id=saved_id) {{ word{k} = 0x6f }}
    // Non-working harts execute: park: wfi; jal x0, park.
    if ((1 << saved_id) & 0x5009) == 0 {{
      word{k} = 0x13
      if pc{k} == ent{k} {{ word{k} = 0x10500073 }}
      if pc{k} == (ent{k} + 4) {{ word{k} = 0xffdff06f }}
    }}
"""
    return result


def generate(out, trace=False):
    out.mkdir(parents=True, exist_ok=True)
    body = BODY.replace('    dut.mem_rsp_data = instruction(addr=address, id=saved_id) | (instruction(addr=address + 4, id=saved_id) << 32)', instruction_words() + '    dut.mem_rsp_data = word0 | (word1 << 32)')
    body = inline_calls(body)
    banner = '// Generated by mixed_soc/scripts/gen_sim.py. Regenerate both twins together.\n'
    prp = banner + '// Four CPUs start together after the host writes eight Gemmini pointer pairs; the host then drives the mesh of the 16x16 TPU.\nconst top = import("lg:MixedSocTop")\n\n'
    prp += '\ntest top.concurrent(cycles:U32 = 36000) {\n  mut dut = top\n' + STATE + '  tick cycles {\n' + body + '  }\n' + END + '}\n'
    # Sample after the active edge. Payloads have protocol meaning only while valid.
    controls = ['host_req_ready', 'host_rsp_valid', 'mem_req_valid', 'mem_rsp_ready',
                'host_req_fire', 'host_rsp_fire', 'mem_req_fire', 'mem_rsp_fire']
    payloads = [(f'{port}_{field}', f'{port}_valid') for port in ('host_rsp', 'mem_req')
                for field in ('addr', 'meta', 'data')]
    if trace:
        py = [f'    const pins{i}:U64 = dut.{name}' for i, name in enumerate(controls)]
        for i, (name, valid) in enumerate(payloads, len(controls)):
            py += [f'    mut pins{i}:U64 = 0', f'    if dut.{valid} != 0 {{ pins{i} = dut.{name} }}']
        values = ' '.join('{pins%d}' % i for i in range(len(controls) + len(payloads)))
        py.append('    puts("edge {clock} ' + values + '")')
        prp = prp.replace('    step\n', '    step\n' + '\n'.join(py) + '\n')
    (out/'mixed_soc_tb.prp').write_text(prp)
    cxx = banner + '#include <cstdint>\n#include <cstdio>\n#include <cstdlib>\n#include <cstring>\n#ifdef NDEBUG\n#undef NDEBUG\n#endif\n#include <cassert>\n#include "VMixedSocTop.h"\n#include "verilated.h"\n'
    cxx += '''int main(int argc, char **argv) {
  uint64_t cycles = 36000;
  for(int i=1;i<argc;++i) {
    if(!std::strcmp(argv[i], "--cycles") && i+1<argc) cycles=std::strtoull(argv[++i],nullptr,0);
    else return 2;
  }
  Verilated::commandArgs(argc,argv);
  auto *dut = new VMixedSocTop;
'''
    cxx += cpp(STATE) + '\n  for(uint64_t cycle=0;cycle<cycles;++cycle) {\n' + cpp(body) + '\n  }\n' + cpp(END) + '\n  dut->final(); delete dut;\n}\n'
    if trace:
        args = [f'dut->{p}' for p in controls] + [f'(dut->{v} ? dut->{p} : 0)' for p, v in payloads]
        row = '    std::printf("edge ' + ' '.join(['%llu'] * (1 + len(args))) + '\\n", ' + ', '.join(
            '(unsigned long long)' + x for x in ['cycle', *args]) + ');'
        cxx = cxx.replace('    uint64_t obs = 0;', row + '\n    uint64_t obs = 0;')
    (out/'mixed_soc_tb_verilator.cpp').write_text(cxx.replace('\\\\n', '\\n'))


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=HERE / 'sim')
    parser.add_argument('--trace', action='store_true', help='emit one post-edge pin sample per cycle')
    args = parser.parse_args()
    generate(args.out, args.trace)
