// Wrapper binding CVA6's tag_cmp to CONCRETE types.
//
// tag_cmp takes its cache-line types as MODULE PARAMETERS
// (`parameter type l_data_t = logic`), which cva6 binds at instantiation. A
// standalone compile leaves them as `logic`, and the whole tag comparison then
// degenerates: rdata_i collapses to one bit per way with no .tag/.valid, and
// hit_way_o ends up undriven. Every property over it would be vacuous.
//
// So this wrapper reproduces the binding std_nbdcache.sv:269 performs, with the
// same cache_line_t / cl_be_t localparams it declares (std_nbdcache.sv:51-62),
// giving the real 44-bit tag compare against a struct-typed line array.
`ifndef TAG_CMP_WRAP_SV
`define TAG_CMP_WRAP_SV

module tag_cmp_wrap
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg  = build_config_pkg::build_config(cva6_config_pkg::cva6_cfg),
    parameter int unsigned           NR_PORTS = 3
) (
    input logic clk_i,
    input logic rst_ni,

    input  logic [NR_PORTS-1:0][CVA6Cfg.DCACHE_SET_ASSOC-1:0] req_i,
    output logic [NR_PORTS-1:0]                               gnt_o,
    input  logic [NR_PORTS-1:0][CVA6Cfg.DCACHE_TAG_WIDTH-1:0] tag_i,
    output logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0]               hit_way_o,
    // the cache line array, flattened at this boundary so the port list stays
    // a plain bus (the struct shape is what tag_cmp sees internally)
    input  logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0][CVA6Cfg.DCACHE_TAG_WIDTH+CVA6Cfg.DCACHE_LINE_WIDTH+1:0] rdata_i
);

  localparam type cache_line_t = struct packed {
    logic [CVA6Cfg.DCACHE_TAG_WIDTH-1:0]  tag;
    logic [CVA6Cfg.DCACHE_LINE_WIDTH-1:0] data;
    logic                                 valid;
    logic                                 dirty;
  };
  localparam type cl_be_t = struct packed {
    logic [(CVA6Cfg.DCACHE_TAG_WIDTH+7)/8-1:0]  tag;
    logic [(CVA6Cfg.DCACHE_LINE_WIDTH+7)/8-1:0] data;
    logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0]        vldrty;
  };

  cache_line_t [CVA6Cfg.DCACHE_SET_ASSOC-1:0] rdata;
  assign rdata = rdata_i;

  tag_cmp #(
      .CVA6Cfg   (CVA6Cfg),
      .NR_PORTS  (NR_PORTS),
      .ADDR_WIDTH(CVA6Cfg.DCACHE_INDEX_WIDTH),
      .l_data_t  (cache_line_t),
      .l_be_t    (cl_be_t)
  ) i_tag_cmp (
      .clk_i,
      .rst_ni,
      .req_i,
      .gnt_o,
      .addr_i ('0),
      .wdata_i('0),
      .we_i   ('0),
      .be_i   ('0),
      .rdata_o(),
      .tag_i,
      .hit_way_o,
      .req_o  (),
      .addr_o (),
      .wdata_o(),
      .we_o   (),
      .be_o   (),
      .rdata_i(rdata)
  );
endmodule
`endif
