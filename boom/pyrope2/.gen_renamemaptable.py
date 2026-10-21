#!/usr/bin/env python3
"""Emit RenameMapTable.prp for SmallBoomV4 config.

Mirrors firtool scalar expansion:
  - map_table_0..31          (sync-reset to 0)
  - com_map_table_0..31      (sync-reset to 0)
  - br_snapshots_T_I         (8 tags x 32 slots; no sync reset)

No reg-arrays, no 2D reg writes -> both upass.tolg gaps avoided.
"""
import sys

NUM_LREG = 32
NUM_BR = 8
PREG_SZ = 6

L = []
def E(s=""): L.append(s)

E("// RenameMapTable - SmallBoomV4 (plWidth=1, numLregs=32, numPregs=64, maxBrCount=8, float=false).")
E("// Auto-emitted by /tmp/gen_renamemaptable.py. Hand-edits WILL be clobbered.")
E("//")
E("// LEC strategy: scalarize all state to mirror firtool's emit (320 regs).")
E("// This dodges both upass.tolg gaps because there is no reg-array anywhere.")
E("// Reset wires only to map_table_* and com_map_table_* (br_snapshots has no")
E("// sync reset in the .sv -- randomize-only).")
E("")
E("pub mod RenameMapTable::[timecheck=false](")
E("  clock:Clock, reset:u1,")
E("  io_map_reqs_0_lrs1:u6, io_map_reqs_0_lrs2:u6, io_map_reqs_0_ldst:u6,")
E("  io_remap_reqs_0_ldst:u6, io_remap_reqs_0_pdst:u6, io_remap_reqs_0_valid:u1,")
E("  io_com_remap_reqs_0_ldst:u6, io_com_remap_reqs_0_pdst:u6, io_com_remap_reqs_0_valid:u1,")
E("  io_ren_br_tags_1_valid:u1, io_ren_br_tags_1_bits:u3,")
E("  io_brupdate_b2_uop_br_tag:u3, io_brupdate_b2_mispredict:u1,")
E("  io_rollback:u1")
E(") -> (")
E("  io_map_resps_0_prs1:u6@[],")
E("  io_map_resps_0_prs2:u6@[],")
E("  io_map_resps_0_stale_pdst:u6@[]")
E(") {")
E("")

E("  // ========= map_table_i : sync-reset to i =========")
for i in range(NUM_LREG):
    E(f"  reg map_table_{i:<2}:u6:[reset_pin=reset] = {i}")
E("")
E("  // ========= com_map_table_i : sync-reset to i =========")
for i in range(NUM_LREG):
    E(f"  reg com_map_table_{i:<2}:u6:[reset_pin=reset] = {i}")
E("")
E("  // ========= br_snapshots_T_I : no sync reset (randomize-only in .sv) =========")
for t in range(NUM_BR):
    for i in range(NUM_LREG):
        E(f"  reg br_snapshots_{t}_{i:<2}:u6")
E("")

def nway_mux(out, key, src_fn, N=NUM_LREG, indent="  "):
    """out = if key==0 { src_fn(0) } elif key==1 { ... } ... else { src_fn(N-1) }"""
    E(f"{indent}{out} = if   {key} == 0 {{ {src_fn(0)} }}")
    pad = " " * (len(out) + 3)
    for i in range(1, N - 1):
        E(f"{indent}{pad}elif {key} == {i:>2} {{ {src_fn(i)} }}")
    E(f"{indent}{pad}else            {{ {src_fn(N-1)} }}")

E("  // ========= READ: 32-way muxes for prs1 / prs2 / stale_pdst =========")
E("  // firtool indexes by lrs[4:0] (only 32 slots).  Slice to u5 so the")
E("  // u6 'high' bit doesn't drop us into the catch-all 'else'.")
E("  wire lrs1_idx:u5 = io_map_reqs_0_lrs1#[0..=4]")
E("  wire lrs2_idx:u5 = io_map_reqs_0_lrs2#[0..=4]")
E("  wire ldst_idx:u5 = io_map_reqs_0_ldst#[0..=4]")
nway_mux("io_map_resps_0_prs1      ", "lrs1_idx", lambda i: f"map_table_{i}")
E("")
nway_mux("io_map_resps_0_prs2      ", "lrs2_idx", lambda i: f"map_table_{i}")
E("")
nway_mux("io_map_resps_0_stale_pdst", "ldst_idx", lambda i: f"map_table_{i}")
E("")

E("  // ========= one-hot ldst decoders =========")
for i in range(NUM_LREG):
    E(f"  wire remap_hit_{i:<2}:u1 = if io_remap_reqs_0_valid != 0 and io_remap_reqs_0_ldst == {i} {{ 1 }} else {{ 0 }}")
E("")
for i in range(NUM_LREG):
    E(f"  wire com_remap_hit_{i:<2}:u1 = if io_com_remap_reqs_0_valid != 0 and io_com_remap_reqs_0_ldst == {i} {{ 1 }} else {{ 0 }}")
E("")

E("  // ========= per-slot snap_restore_i (8-way mux on br_tag) =========")
for i in range(NUM_LREG):
    name = f"snap_restore_{i:<2}"
    pad = " " * (len(name) + 3)
    E(f"  wire {name}:u6 = if   io_brupdate_b2_uop_br_tag == 0 {{ br_snapshots_0_{i} }}")
    for t in range(1, NUM_BR - 1):
        E(f"  {pad}        elif io_brupdate_b2_uop_br_tag == {t} {{ br_snapshots_{t}_{i} }}")
    E(f"  {pad}        else                                {{ br_snapshots_{NUM_BR-1}_{i} }}")
E("")

E("  // ========= next_map_i : post-remap view for snapshot capture =========")
for i in range(NUM_LREG):
    E(f"  wire next_map_{i:<2}:u6 = if remap_hit_{i} != 0 {{ io_remap_reqs_0_pdst }} else {{ map_table_{i} }}")
E("")

E("  // ========= map_table write: priority mispredict > rollback > remap =========")
E("  if io_brupdate_b2_mispredict != 0 {")
for i in range(NUM_LREG):
    E(f"    map_table_{i:<2} = snap_restore_{i}")
E("  } elif io_rollback != 0 {")
for i in range(NUM_LREG):
    E(f"    map_table_{i:<2} = com_map_table_{i}")
E("  } else {")
for i in range(NUM_LREG):
    E(f"    if remap_hit_{i} != 0 {{ map_table_{i:<2} = io_remap_reqs_0_pdst }}")
E("  }")
E("")

E("  // ========= com_map_table write =========")
for i in range(NUM_LREG):
    E(f"  if com_remap_hit_{i} != 0 {{ com_map_table_{i:<2} = io_com_remap_reqs_0_pdst }}")
E("")

E("  // ========= br_snapshots write (on io_ren_br_tags_1_valid) =========")
E("  if io_ren_br_tags_1_valid != 0 {")
for t in range(NUM_BR):
    if t == 0:
        E(f"    if   io_ren_br_tags_1_bits == 0 {{")
    elif t == NUM_BR - 1:
        E(f"    else {{")
    else:
        E(f"    elif io_ren_br_tags_1_bits == {t} {{")
    for i in range(NUM_LREG):
        E(f"      br_snapshots_{t}_{i:<2} = next_map_{i}")
    E("    }")
E("  }")
E("}")

sys.stdout.write("\n".join(L) + "\n")
