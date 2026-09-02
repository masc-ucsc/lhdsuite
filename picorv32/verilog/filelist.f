// picorv32, in elaboration order. Paths are relative to this file (slang -F).
//
// picorv32.v holds every module upstream ships (the CPU, the register file, the
// PCPI mul/div units and the AXI/Wishbone wrappers); only the cone under
// picorv32_top's `--top` is elaborated, so the rest costs front-end time and
// emits nothing.
picorv32.v
picorv32_top.v
