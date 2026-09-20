module cva6_oracle(input logic clk_i,rst_ni,
 input logic ar_ready,r_valid,r_last,aw_ready,w_ready,b_valid,
 input logic [3:0] r_id,b_id,input logic [63:0] r_data,
 output logic ar_valid,r_ready,aw_valid,w_valid,w_last,b_ready,ex_valid,
 output logic [7:0] ar_len,output logic [3:0] ar_id,
 output logic [3:0] aw_id,output logic [63:0] ar_addr,aw_addr,w_data,
 output logic [1:0] commit_ack);
cva6 dut(.clk_i(clk_i),.rst_ni(rst_ni),.boot_addr_i(64'h80000000),.hart_id_i(64'b0),
.irq_i(2'b0),.ipi_i(1'b0),.time_irq_i(1'b0),.debug_req_i(1'b0),
.cvxif_resp_i('{default:'0,compressed_ready:1'b1,issue_ready:1'b1,register_ready:1'b1}),
.noc_resp_i('{aw_ready:aw_ready,ar_ready:ar_ready,w_ready:w_ready,b_valid:b_valid,
b:'{default:'0,id:b_id},r_valid:r_valid,r:'{default:'0,id:r_id,data:r_data,last:r_last}}),
.noc_req_o(),.cvxif_req_o(),.rvfi_probes_o());
assign ar_valid=dut.noc_req_o.ar_valid;
assign ar_id=dut.noc_req_o.ar.id;
assign ar_len=dut.noc_req_o.ar.len;
assign ar_addr=dut.noc_req_o.ar.addr;
assign r_ready=dut.noc_req_o.r_ready;
assign aw_valid=dut.noc_req_o.aw_valid;
assign aw_addr=dut.noc_req_o.aw.addr;
assign aw_id=dut.noc_req_o.aw.id;
assign w_valid=dut.noc_req_o.w_valid;
assign w_data=dut.noc_req_o.w.data;
assign w_last=dut.noc_req_o.w.last;
assign b_ready=dut.noc_req_o.b_ready;
assign commit_ack=dut.rvfi_probes_o.instr.commit_ack;
assign ex_valid=dut.rvfi_probes_o.instr.ex_commit_valid;
endmodule
