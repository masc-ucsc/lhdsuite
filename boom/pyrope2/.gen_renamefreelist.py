#!/usr/bin/env python3
"""Emit RenameFreeList.prp for SmallBoomV4 config.

numPregs=52, allocWidth=1, deallocWidth=1, isImm=false, maxBrCount=8.
Initial allocation (hardcoded in this instance): 52'hFFFFF00000000
(upper 20 bits set -> pregs 32..51 are initially free).
"""
import sys

N = 52
NUM_BR = 8
INIT_FREE = 0xFFFFF00000000   # bits 51..32 set, bits 31..0 clear

L = []
def E(s=""): L.append(s)

E("// RenameFreeList - SmallBoomV4 (numPregs=52, alloc/dealloc=1, isImm=false, maxBrCount=8).")
E("// Scalarized to mirror firtool: free_list / spec_alloc_list / br_alloc_lists_0..7 are u52.")
E("// Auto-emitted by /tmp/gen_renamefreelist.py.")
E("")
E("pub mod RenameFreeList::[timecheck=false](")
E("  clock:Clock, reset:u1,")
E("  io_reqs_0:u1,")
E("  io_despec_0_valid:u1,  io_despec_0_bits:u6,")
E("  io_dealloc_0_valid:u1, io_dealloc_0_bits:u6,")
E("  io_ren_br_tags_1_valid:u1, io_ren_br_tags_1_bits:u3,")
E("  io_brupdate_b2_uop_br_tag:u3, io_brupdate_b2_mispredict:u1,")
E("  io_rollback:u1")
E(") -> (")
E("  io_alloc_pregs_0_valid:u1@[],")
E("  io_alloc_pregs_0_bits:u6@[],")
E("  io_debug_freelist:u52@[]")
E(") {")
E("")

# State regs
E(f"  // ========= state (reset values match firtool emit) =========")
E(f"  reg free_list:u52:[reset_pin=reset] = 0x{INIT_FREE:x}")
E(f"  reg spec_alloc_list:u52:[reset_pin=reset] = 0")
E(f"  reg r_valid:u1:[reset_pin=reset] = 0")
E(f"  reg r_sel:u6")
E(f"  reg com_deallocs_REG_0_valid:u1")
E(f"  reg com_deallocs_REG_0_bits:u6")
for t in range(NUM_BR):
    E(f"  reg br_alloc_lists_{t}:u52")
E("")

# sels_0 : 52-way priority encoder on free_list, result is one-hot u52
E("  // ========= sels_0 : one-hot of the lowest set bit in free_list (u52) =========")
E("  wire sels_0:u52 = if   free_list#[0]  != 0 { 0x1 }")
for i in range(1, N - 1):
    E(f"                    elif free_list#[{i:>2}] != 0 {{ 0x{1<<i:x} }}")
E(f"                    else                    {{ 0x{1<<(N-1):x} }}")
E("")

# r_sel_next : index of lowest set bit (u6)
E("  // ========= r_sel_next : OHToUInt(sels_0), computed as lowest-set-bit index =========")
E("  wire r_sel_next:u6 = if   free_list#[0]  != 0 { 0 }")
for i in range(1, N - 1):
    E(f"                       elif free_list#[{i:>2}] != 0 {{ {i:>2} }}")
E(f"                       else                    {{ {N-1} }}")
E("")

# br_deallocs : _GEN[br_tag] & {52{mispredict}}  (8-way mux over br_alloc_lists)
E("  // ========= br_deallocs = br_alloc_lists[br_tag] & {52{mispredict}} =========")
E("  wire br_lookup:u52 = if   io_brupdate_b2_uop_br_tag == 0 { br_alloc_lists_0 }")
for t in range(1, NUM_BR - 1):
    E(f"                       elif io_brupdate_b2_uop_br_tag == {t} {{ br_alloc_lists_{t} }}")
E(f"                       else                                {{ br_alloc_lists_{NUM_BR-1} }}")
E("  wire br_deallocs:u52 = if io_brupdate_b2_mispredict != 0 { br_lookup } else { 0 }")
E("")

# com_deallocs_T : 1 << com_deallocs_REG_0_bits (u64 in SV, but we only use low 52)
# dealloc_mask = _com_deallocs_T[51:0] & {52{com_deallocs_REG_0_valid}} | br_deallocs | spec_alloc_list & {52{io_rollback}}
E("  // widened '1' for u52 shifts (avoids inline type-cast on literal)")
E("  const one_u52:u52 = 1")
E("")
E("  // ========= dealloc_mask =========")
E("  wire com_deallocs_oh:u52 = one_u52 << com_deallocs_REG_0_bits")
E("  wire com_deallocs_mask:u52 = if com_deallocs_REG_0_valid != 0 { com_deallocs_oh } else { 0 }")
E("  wire rollback_mask:u52 = if io_rollback != 0 { spec_alloc_list } else { 0 }")
E("  wire dealloc_mask:u52 = com_deallocs_mask | br_deallocs | rollback_mask")
E("")

# alloc_masks_0 = (1 << r_sel) & {52{io_reqs_0}}   (note: in SV this is _io_debug_freelist_T[51:0])
# Wait - alloc_masks_0 in SV uses r_sel for 1<<r_sel, that's the OLD r_sel (register), not r_sel_next
# Actually looking at SV again: _io_debug_freelist_T = 64'h1 << r_sel ; alloc_masks_0 = _io_debug_freelist_T[51:0] & {52{io_reqs_0}}
# Yes, r_sel is the current register value, used for both debug and alloc_masks.
E("  // ========= alloc_masks_0 = (1 << r_sel) & {52{io_reqs_0}} =========")
E("  wire r_sel_oh:u52 = one_u52 << r_sel")
E("  wire alloc_masks_0:u52 = if io_reqs_0 != 0 { r_sel_oh } else { 0 }")
E("")

# com_despec_T : 1 << io_despec_0_bits ; dealloc_mask | ~(com_despec_T & {52{io_despec_0_valid}})
E("  // ========= com_despec_mask = (1 << io_despec_0_bits) & {52{io_despec_0_valid}} =========")
E("  wire com_despec_oh:u52 = one_u52 << io_despec_0_bits")
E("  wire com_despec_mask:u52 = if io_despec_0_valid != 0 { com_despec_oh } else { 0 }")
E("")

# sel_fire_0 = (~r_valid | io_reqs_0) & (|sels_0)
E("  // ========= sel_fire_0 =========")
E("  wire not_r_valid_or_req:u1 = if r_valid == 0 or io_reqs_0 != 0 { 1 } else { 0 }")
E("  wire sels_nonzero:u1 = if sels_0 != 0 { 1 } else { 0 }")
E("  wire sel_fire_0:u1 = if not_r_valid_or_req != 0 and sels_nonzero != 0 { 1 } else { 0 }")
E("")

# io_debug_freelist_0 = free_list | (1 << r_sel) & {52{r_valid}}
E("  // ========= io_debug_freelist_0 = free_list | r_sel_oh & {52{r_valid}} =========")
E("  wire r_sel_oh_gated:u52 = if r_valid != 0 { r_sel_oh } else { 0 }")
E("  io_debug_freelist = free_list | r_sel_oh_gated")
E("")

# Register writes
E("  // ========= free_list <= free_list & ~(sels_0 & {52{sel_fire_0}}) | dealloc_mask =========")
E("  wire sels_gated:u52 = if sel_fire_0 != 0 { sels_0 } else { 0 }")
E("  free_list = (free_list & ~sels_gated) | dealloc_mask")
E("")

E("  // ========= spec_alloc_list <= (spec_alloc_list | alloc_masks_0) & ~dealloc_mask & ~com_despec_mask =========")
E("  spec_alloc_list = (spec_alloc_list | alloc_masks_0) & ~dealloc_mask & ~com_despec_mask")
E("")

E("  // ========= r_valid <= (r_valid & ~io_reqs_0) | |sels_0 =========")
E("  wire r_valid_hold:u1 = if r_valid != 0 and io_reqs_0 == 0 { 1 } else { 0 }")
E("  r_valid = if r_valid_hold != 0 or sels_nonzero != 0 { 1 } else { 0 }")
E("")

E("  // ========= r_sel <= r_sel_next if sel_fire_0 =========")
E("  if sel_fire_0 != 0 { r_sel = r_sel_next }")
E("")

E("  // ========= com_deallocs_REG_0 <= RegNext(io_dealloc_0) =========")
E("  com_deallocs_REG_0_valid = io_dealloc_0_valid")
E("  com_deallocs_REG_0_bits  = io_dealloc_0_bits")
E("")

# br_alloc_lists_i <= (tag==i & valid) ? 0 : br_alloc_lists_i & ~br_deallocs | alloc_masks_0
E("  // ========= br_alloc_lists_i: clear-on-tag-write-else-update =========")
for t in range(NUM_BR):
    E(f"  br_alloc_lists_{t} = if io_ren_br_tags_1_bits == {t} and io_ren_br_tags_1_valid != 0 {{ 0 }}")
    E(f"                       else {{ (br_alloc_lists_{t} & ~br_deallocs) | alloc_masks_0 }}")
E("")

E("  // ========= outputs =========")
E("  io_alloc_pregs_0_valid = r_valid")
E("  io_alloc_pregs_0_bits  = r_sel")
E("}")

sys.stdout.write("\n".join(L) + "\n")
