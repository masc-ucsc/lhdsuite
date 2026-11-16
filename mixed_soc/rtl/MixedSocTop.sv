// Scalar boundary for the matched Pyrope and C++ drivers.
module MixedSocTop import mixed_packet::*; (
  input logic clock, reset,
  output logic host_req_fire, host_rsp_fire, mem_req_fire, mem_rsp_fire,
  output logic [39:0] seen_mem_meta, seen_host_meta,
  output logic [31:0] seen_mem_addr,
  output logic [63:0] seen_host_data,
  input logic [15:0] core_enable,
  input logic host_req_valid,
  output logic host_req_ready,
  input logic [63:0] host_req_data,
  input logic [31:0] host_req_addr,
  input logic [39:0] host_req_meta,
  output logic host_rsp_valid,
  input logic host_rsp_ready,
  output logic [63:0] host_rsp_data,
  output logic [31:0] host_rsp_addr,
  output logic [39:0] host_rsp_meta,
  output logic mem_req_valid,
  input logic mem_req_ready,
  output logic [63:0] mem_req_data,
  output logic [31:0] mem_req_addr,
  output logic [39:0] mem_req_meta,
  input logic mem_rsp_valid,
  output logic mem_rsp_ready,
  input logic [63:0] mem_rsp_data,
  input logic [31:0] mem_rsp_addr,
  input logic [39:0] mem_rsp_meta);
  packet_t host_req;
  assign host_req.data=host_req_data;
  assign host_req.addr=host_req_addr;
  assign {host_req.origin,host_req.target,host_req.ch,host_req.opcode,host_req.size,host_req.param,host_req.tl_source,host_req.sink,host_req.mask,host_req.corrupt,host_req.denied}=host_req_meta;
  packet_t host_rsp;
  assign host_rsp_data=host_rsp.data;
  assign host_rsp_addr=host_rsp.addr;
  assign host_rsp_meta={host_rsp.origin,host_rsp.target,host_rsp.ch,host_rsp.opcode,host_rsp.size,host_rsp.param,host_rsp.tl_source,host_rsp.sink,host_rsp.mask,host_rsp.corrupt,host_rsp.denied};
  packet_t mem_req;
  assign mem_req_data=mem_req.data;
  assign mem_req_addr=mem_req.addr;
  assign mem_req_meta={mem_req.origin,mem_req.target,mem_req.ch,mem_req.opcode,mem_req.size,mem_req.param,mem_req.tl_source,mem_req.sink,mem_req.mask,mem_req.corrupt,mem_req.denied};
  packet_t mem_rsp;
  assign mem_rsp.data=mem_rsp_data;
  assign mem_rsp.addr=mem_rsp_addr;
  assign {mem_rsp.origin,mem_rsp.target,mem_rsp.ch,mem_rsp.opcode,mem_rsp.size,mem_rsp.param,mem_rsp.tl_source,mem_rsp.sink,mem_rsp.mask,mem_rsp.corrupt,mem_rsp.denied}=mem_rsp_meta;
  mixed_soc soc(.clock,.reset,.core_enable,
    .host_req_valid,.host_req_ready,.host_req,.host_rsp_valid,.host_rsp_ready,.host_rsp,
    .mem_req_valid,.mem_req_ready,.mem_req,.mem_rsp_valid,.mem_rsp_ready,.mem_rsp);
  // Registered transfer observations let both drivers read below step without
  // mistaking the post-edge combinational ready/valid for the consumed beat.
  always_ff @(posedge clock) begin
    host_req_fire <= !reset && host_req_valid && host_req_ready;
    host_rsp_fire <= !reset && host_rsp_valid && host_rsp_ready;
    mem_req_fire <= !reset && mem_req_valid && mem_req_ready;
    mem_rsp_fire <= !reset && mem_rsp_valid && mem_rsp_ready;
    if(mem_req_valid && mem_req_ready) begin seen_mem_meta<=mem_req_meta; seen_mem_addr<=mem_req_addr; end
    if(host_rsp_valid && host_rsp_ready) begin seen_host_meta<=host_rsp_meta; seen_host_data<=host_rsp_data; end
  end
endmodule
