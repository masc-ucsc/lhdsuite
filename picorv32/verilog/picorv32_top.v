`timescale 1 ns / 1 ps
//
// The suite's picorv32 configuration. picorv32.v itself is vendored VERBATIM
// from upstream (YosysHQ/picorv32, ISC — see COPYING); this wrapper is the one
// file here that is not, and it exists only to pin the parameters.
//
// Why a wrapper rather than the bare `picorv32` top: the module's defaults
// leave the barrel shifter and the compressed decoder unelaborated, and a
// parameter that is off is not "a feature turned off" to the front end — it is
// a whole cone that constant-folds away before any of these scenarios sees it.
// The suite would then benchmark, LEC and simulate a CPU that is missing the
// shift and RVC paths, while the target names said "picorv32". Turning them on
// here is the same discipline as cva6's tag_cmp_wrap: benchmark the real
// configuration, not the degenerate one.
//
// PCPI multiply/divide and IRQ stay OFF in this benchmark configuration.
// The maintained Pyrope now implements PCPI/M/D; ../check_configurations.py
// checks those configurations separately without changing the benchmark.
// IRQ remains unimplemented. See ../validation.md for current proof status.
//
// The port list is picorv32's simple (non-look-ahead, non-AXI) memory
// interface plus the IRQ pins; sim/picorv32_prog_tb.prp is the memory.
module picorv32_top (
	input             clk,
	input             resetn,
	output            trap,

	output            mem_valid,
	output            mem_instr,
	input             mem_ready,
	output     [31:0] mem_addr,
	output     [31:0] mem_wdata,
	output     [ 3:0] mem_wstrb,
	input      [31:0] mem_rdata,

	input      [31:0] irq,
	output     [31:0] eoi
);
	picorv32 #(
		.COMPRESSED_ISA (1),
		.BARREL_SHIFTER (1),
		.ENABLE_MUL     (0),
		.ENABLE_DIV     (0),
		.ENABLE_IRQ     (0)
	) cpu (
		.clk       (clk),
		.resetn    (resetn),
		.trap      (trap),

		.mem_valid (mem_valid),
		.mem_instr (mem_instr),
		.mem_ready (mem_ready),
		.mem_addr  (mem_addr),
		.mem_wdata (mem_wdata),
		.mem_wstrb (mem_wstrb),
		.mem_rdata (mem_rdata),

		// The PCPI coprocessor interface is unused in this configuration.
		.pcpi_valid(),
		.pcpi_insn (),
		.pcpi_rs1  (),
		.pcpi_rs2  (),
		.pcpi_wr   (1'b0),
		.pcpi_rd   (32'b0),
		.pcpi_wait (1'b0),
		.pcpi_ready(1'b0),

		.irq       (irq),
		.eoi       (eoi)
	);
endmodule
