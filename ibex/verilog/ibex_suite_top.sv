// Parameter-pinning wrapper for the suite (the only hand-written Verilog here).
//
// ibex_top keeps its own defaults (RV32I + fast M + Zca/Zcb/Zcmp, FF register
// file, no PMP / icache / SecureIbex / CHERIoT). Interrupts, debug, scrambling,
// the revocation bus and the integrity bits are tied off, as in Ibex's
// examples/simple_system, so only the instruction and data buses are ports.
module ibex_suite_top (
  input  logic        clk_i,
  input  logic        rst_ni,

  output logic        instr_req_o,
  input  logic        instr_gnt_i,
  input  logic        instr_rvalid_i,
  output logic [31:0] instr_addr_o,
  input  logic [31:0] instr_rdata_i,

  output logic        data_req_o,
  input  logic        data_gnt_i,
  input  logic        data_rvalid_i,
  output logic        data_we_o,
  output logic [3:0]  data_be_o,
  output logic [31:0] data_addr_o,
  output logic [31:0] data_wdata_o,
  input  logic [31:0] data_rdata_i,

  output logic        core_sleep_o
);

  ibex_top u_top (
    .clk_i                    (clk_i),
    .rst_ni                   (rst_ni),
    .test_en_i                (1'b0),
    .scan_rst_ni              (1'b1),
    .ram_cfg_icache_tag_i     ('{default: prim_ram_1p_pkg::RAM_1P_CFG_REQ_DEFAULT}),
    .ram_cfg_icache_tag_o     (),
    .ram_cfg_icache_data_i    ('{default: prim_ram_1p_pkg::RAM_1P_CFG_REQ_DEFAULT}),
    .ram_cfg_icache_data_o    (),
    .cheriot_enable_i         (ibex_pkg::IbexMuBiOff),
    .hart_id_i                (32'b0),
    .boot_addr_i              (32'h0000_0000),
    .trvk_heap_base_addr_i    (32'h0000_0000),

    .instr_req_o              (instr_req_o),
    .instr_gnt_i              (instr_gnt_i),
    .instr_rvalid_i           (instr_rvalid_i),
    .instr_addr_o             (instr_addr_o),
    .instr_rdata_i            (instr_rdata_i),
    .instr_rdata_intg_i       (7'b0),
    .instr_err_i              (1'b0),

    .data_req_o               (data_req_o),
    .data_gnt_i               (data_gnt_i),
    .data_rvalid_i            (data_rvalid_i),
    .data_we_o                (data_we_o),
    .data_be_o                (data_be_o),
    .data_addr_o              (data_addr_o),
    .data_wdata_o             (data_wdata_o),
    .data_wdata_intg_o        (),
    .data_tag_o               (),
    .data_rdata_i             (data_rdata_i),
    .data_rdata_intg_i        (7'b0),
    .data_tag_i               (1'b0),
    .data_err_i               (1'b0),

    .trvk_revbm_req_o         (),
    .trvk_revbm_gnt_i         (1'b0),
    .trvk_revbm_rvalid_i      (1'b0),
    .trvk_revbm_addr_o        (),
    .trvk_revbm_rdata_i       (32'b0),
    .trvk_revbm_rdata_intg_i  (7'b0),
    .trvk_revbm_err_i         (1'b0),

    .irq_software_i           (1'b0),
    .irq_timer_i              (1'b0),
    .irq_external_i           (1'b0),
    .irq_fast_i               (15'b0),
    .irq_nm_i                 (1'b0),

    .scramble_key_valid_i     (1'b0),
    .scramble_key_i           ('0),
    .scramble_nonce_i         ('0),
    .scramble_req_o           (),

    .debug_req_i              (1'b0),
    .crash_dump_o             (),
    .double_fault_seen_o      (),

    .fetch_enable_i           (ibex_pkg::IbexMuBiOn),
    .mcounteren_writable_i    (ibex_pkg::IbexMuBiOn),
    .alert_minor_o            (),
    .alert_major_internal_o   (),
    .alert_major_bus_o        (),
    .core_sleep_o             (core_sleep_o),
    .lockstep_cmp_en_o        (),

    .data_req_shadow_o        (),
    .data_we_shadow_o         (),
    .data_be_shadow_o         (),
    .data_addr_shadow_o       (),
    .data_wdata_shadow_o      (),
    .data_wdata_intg_shadow_o (),
    .instr_req_shadow_o       (),
    .instr_addr_shadow_o      ()
  );

endmodule
