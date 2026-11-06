// Simulation-only wrapper for the 8x8 GemminiTPU (256-bit fields); mirrors sim/GemminiSimTop.prp.
module GemminiSimTop(
  input clock, input reset,
  input a_valid, input [63:0] a_bits, input b_valid, input [63:0] b_bits, input d_valid, input [63:0] d_bits,
  input req_valid, input req_tag_id, input req_dataflow, input req_propagate, input [4:0] req_shift,
  input req_a_transpose, input req_bd_transpose, input [3:0] req_total_rows, input [1:0] req_flush,
  input wr_valid, input [5:0] wr_addr, input [63:0] wr_data_0, input [63:0] wr_data_1, input [63:0] wr_data_2,
  input [63:0] wr_data_3, input wr_acc, input [31:0] wr_mask,
  input rd_valid, input [31:0] rd_scale, input [5:0] rd_addr, input [2:0] rd_act, input rd_full, input rd_fromDMA,
  input rd_resp_ready,
  output a_ready, output b_ready, output d_ready, output req_ready,
  output resp_valid, output resp_tag_id, output [63:0] resp_data_0, output [63:0] resp_data_1,
  output [63:0] resp_data_2, output [63:0] resp_data_3, output [3:0] resp_total_rows, output resp_last,
  output wr_ready, output rd_req_ready, output rd_resp_valid, output [63:0] rd_data_0, output [63:0] rd_data_1,
  output [63:0] rd_data_2, output [63:0] rd_data_3,
  output rd_resp_fromDMA, output [31:0] rd_resp_scale, output [2:0] rd_resp_act, output [1:0] rd_resp_bank);
  wire [262:0] mesh_resp;
  wire [421:0] rd_resp;
  GemminiTPU tpu(.clock(clock), .reset(reset),
    .io_mesh_a_ready(a_ready), .io_mesh_a_valid(a_valid), .io_mesh_a_bits(a_bits),
    .io_mesh_b_ready(b_ready), .io_mesh_b_valid(b_valid), .io_mesh_b_bits(b_bits),
    .io_mesh_d_ready(d_ready), .io_mesh_d_valid(d_valid), .io_mesh_d_bits(d_bits),
    .io_mesh_req_ready(req_ready), .io_mesh_req_valid(req_valid),
    .io_mesh_req_bits({req_tag_id, req_dataflow, req_propagate, req_shift, req_a_transpose, req_bd_transpose,
                       req_total_rows, req_flush}),
    .io_mesh_resp(mesh_resp),
    .io_acc_write_ready(wr_ready), .io_acc_write_valid(wr_valid),
    .io_acc_write_bits({wr_addr, wr_data_3, wr_data_2, wr_data_1, wr_data_0, wr_acc, wr_mask}),
    .io_acc_read_req_ready(rd_req_ready), .io_acc_read_req_valid(rd_valid),
    .io_acc_read_req_bits({rd_scale, rd_addr, 32'd0, 32'd0, 32'd0, 32'd0, rd_act, rd_full, rd_fromDMA}),
    .io_acc_read_resp_ready(rd_resp_ready), .io_acc_read_resp_valid(rd_resp_valid),
    .io_acc_read_resp_bits(rd_resp));
  assign resp_valid = mesh_resp[262];
  assign resp_tag_id = mesh_resp[261];
  assign resp_data_3 = mesh_resp[260:197];
  assign resp_data_2 = mesh_resp[196:133];
  assign resp_data_1 = mesh_resp[132:69];
  assign resp_data_0 = mesh_resp[68:5];
  assign resp_total_rows = mesh_resp[4:1];
  assign resp_last = mesh_resp[0];
  assign rd_data_3 = rd_resp[421:358];
  assign rd_data_2 = rd_resp[357:294];
  assign rd_data_1 = rd_resp[293:230];
  assign rd_data_0 = rd_resp[229:166];
  assign rd_resp_fromDMA = rd_resp[165];
  assign rd_resp_scale = rd_resp[164:133];
  assign rd_resp_act = rd_resp[4:2];
  assign rd_resp_bank = rd_resp[1:0];
endmodule
