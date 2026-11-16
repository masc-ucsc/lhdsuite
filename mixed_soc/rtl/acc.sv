// Single-beat Get/Put MMIO window onto the 16x16 Gemmini TPU: its 64 x 512-bit accumulator and, through registers, the
// systolic mesh. The mesh results feed the accumulator and the host reads both, so the whole TPU is live logic: a mesh
// whose results nothing reads is removed by synthesis, which is what the previous accumulator-only window left behind.
//   +0x0000..0x0fff  accumulator rows, 64 x 64 bytes: eight 64-bit lanes per row, byte-masked puts, gets
//   +0x1000 A_LO   +0x1008 A_HI   the put of A_HI pushes {A_HI, A_LO} (16 int8) to the mesh A port; B and D likewise
//   +0x1010 B_LO   +0x1018 B_HI   +0x1020 D_LO   +0x1028 D_HI
//   +0x1030 REQ    put: pushes a mesh request: [0] tag [1] dataflow [2] propagate [7:3] shift [8] a_transpose
//                  [9] bd_transpose [14:10] total_rows [16:15] flush
//   +0x1038 CTL    put/get: [0] write every mesh result into the accumulator at the next row (wrapping)
//                  [1] accumulate into the row instead of overwriting it
//                  [2] (put only) restart the row counter and clear the lost flag
//   +0x1040 STATUS get: [0] a result waits [1] its tag [6:2] its total_rows [7] last [8] a result was lost
//                  [14:9] the next automatic row
//   +0x1080..0x10b8  the waiting mesh result, eight 64-bit words; reading the last one frees it
module mixed_acc import mixed_packet::*; (
  input logic clock, reset, input logic rxv, output logic rxr, input packet_t rx,
  output logic txv, input logic txr, output packet_t tx);
  typedef enum logic [1:0] {IDLE, READING, REPLY} state_t;
  state_t state;
  packet_t answer;
  logic cmd_ok, get, put, in_acc, in_regs, reg_ok, cmd_req, fire, target_ready, auto_wr, reg_get;
  logic [31:0] offset;
  logic [4:0] sel;
  logic wr_ready, rd_ready, rd_valid, a_ready, b_ready, d_ready, req_ready;
  logic resp_valid, resp_tag, resp_last;
  logic [4:0] resp_rows;
  logic [63:0] rd_data[8], resp_word[8], wr_word[8], held[8], reg_rdata;
  logic [63:0] a_lo, b_lo, d_lo;
  logic [1:0] ctl;
  logic auto_pend;
  logic [5:0] auto_row;
  logic full, full_tag, full_last, full_lost;
  logic [4:0] full_rows;

  assign offset=rx.addr-ACC_BASE;
  assign in_acc=offset<32'h1000;
  assign in_regs=offset[31:8]==24'h10;
  assign sel=offset[7:3];
  assign get=rx.opcode==4; assign put=rx.opcode==0 || rx.opcode==1;
  // Puts reach A_LO..CTL; gets read CTL, STATUS and the eight result words. Registers are 8-byte.
  assign reg_ok=in_regs && rx.size==3 && (put ? sel<5'd8 : (sel==5'd7 || sel==5'd8 || (sel>=5'd16 && sel<5'd24)));
  assign cmd_ok=rx.ch==A && acc_address(rx.addr) && !rx.corrupt && rx.size<=3
                && (rx.addr & ((32'd1<<rx.size)-1))==0 && (get || put) && (in_acc || reg_ok);
  // A mesh result is written into the accumulator one cycle after it appears, from `held`: the inputs of the TPU then never
  // depend on its outputs, which keeps the instance a single node in the evaluation order (and in the emitted Pyrope).
  assign auto_wr=auto_pend;
  always_comb begin
    target_ready=1'b1;
    if(in_acc) target_ready=get ? rd_ready : (wr_ready && !auto_wr);
    else if(put) case(sel)
      5'd1: target_ready=a_ready;
      5'd3: target_ready=b_ready;
      5'd5: target_ready=d_ready;
      5'd6: target_ready=req_ready;
      default: target_ready=1'b1;
    endcase
  end
  assign rxr=state==IDLE && (!cmd_ok || target_ready);
  // A valid never depends on its ready (that would loop through the TPU): the TPU sees the request, rxr is its ready, and
  // the staging registers below act on `fire`, the accepted request.
  assign cmd_req=state==IDLE && rxv && cmd_ok;
  assign fire=cmd_req && rxr;
  assign reg_get=fire && get && !in_acc;
  assign txv=state==REPLY;
  assign tx=answer;
  always_comb begin
    reg_rdata='0;
    if(sel==5'd7) reg_rdata={62'b0,ctl};
    else if(sel==5'd8) reg_rdata={49'b0,auto_row,full_lost,full_last,full_rows,full_tag,full};
    else reg_rdata=held[sel[2:0]];
  end
  always_comb begin
    for(int k=0;k<8;k++) wr_word[k]=auto_wr ? held[k] : rx.data;
  end
  always_ff @(posedge clock) begin
    if(reset) begin state<=IDLE; ctl<='0; auto_pend<=0; auto_row<='0; full<=0; full_lost<=0; end
    else begin
      case(state)
        IDLE: if(rxv && rxr) begin
          answer<='0; answer.ch<=D; answer.target<=rx.origin; answer.tl_source<=rx.tl_source;
          answer.opcode<=get ? 1 : 0; answer.size<=rx.size; answer.addr<=rx.addr; answer.denied<=!cmd_ok;
          if(cmd_ok && get && !in_acc) answer.data<=reg_rdata;
          state<=cmd_ok && get && in_acc ? READING : REPLY;
        end
        READING: if(rd_valid) begin answer.data<=rd_data[answer.addr[5:3]]; state<=REPLY; end
        REPLY: if(txr) state<=IDLE;
        default: state<=IDLE;
      endcase
      if(fire && put && !in_acc) case(sel)
        5'd0: a_lo<=rx.data;
        5'd2: b_lo<=rx.data;
        5'd4: d_lo<=rx.data;
        5'd7: begin ctl<=rx.data[1:0]; if(rx.data[2]) begin auto_row<='0; full_lost<=0; end end
        default: ;
      endcase
      auto_pend<=ctl[0] && resp_valid;
      if(auto_wr) begin
        if(wr_ready) auto_row<=auto_row+6'd1;
        else full_lost<=1;
      end
      // The mesh result has no ready: keep it, and note when a second one overwrites one nobody read.
      if(resp_valid) begin
        for(int k=0;k<8;k++) held[k]<=resp_word[k];
        full_tag<=resp_tag; full_last<=resp_last; full_rows<=resp_rows; full<=1;
        if(full && !(reg_get && sel==5'd23)) full_lost<=1;
      end else if(reg_get && sel==5'd23) full<=0;
    end
  end
  GemminiSimTop gemmini(.clock,.reset,
    .a_valid(cmd_req && put && !in_acc && sel==5'd1),.a_bits_0(a_lo),.a_bits_1(rx.data),
    .b_valid(cmd_req && put && !in_acc && sel==5'd3),.b_bits_0(b_lo),.b_bits_1(rx.data),
    .d_valid(cmd_req && put && !in_acc && sel==5'd5),.d_bits_0(d_lo),.d_bits_1(rx.data),
    .req_valid(cmd_req && put && !in_acc && sel==5'd6),.req_tag_id(rx.data[0]),.req_dataflow(rx.data[1]),
    .req_propagate(rx.data[2]),.req_shift(rx.data[7:3]),.req_a_transpose(rx.data[8]),.req_bd_transpose(rx.data[9]),
    .req_total_rows(rx.data[14:10]),.req_flush(rx.data[16:15]),
    .wr_valid(auto_wr || (cmd_req && put && in_acc)),.wr_addr(auto_wr ? auto_row : rx.addr[11:6]),
    .wr_data_0(wr_word[0]),.wr_data_1(wr_word[1]),.wr_data_2(wr_word[2]),.wr_data_3(wr_word[3]),
    .wr_data_4(wr_word[4]),.wr_data_5(wr_word[5]),.wr_data_6(wr_word[6]),.wr_data_7(wr_word[7]),
    .wr_acc(auto_wr && ctl[1]),.wr_mask(auto_wr ? '1 : (64'(rx.mask) << (8*rx.addr[5:3]))),.wr_ready,
    .rd_valid(cmd_req && get && in_acc),.rd_addr(rx.addr[11:6]),.rd_scale('0),.rd_act('0),.rd_full(1'b1),
    .rd_fromDMA(1'b1),.rd_req_ready(rd_ready),.rd_resp_ready(state==READING),.rd_resp_valid(rd_valid),
    .rd_data_0(rd_data[0]),.rd_data_1(rd_data[1]),.rd_data_2(rd_data[2]),.rd_data_3(rd_data[3]),
    .rd_data_4(rd_data[4]),.rd_data_5(rd_data[5]),.rd_data_6(rd_data[6]),.rd_data_7(rd_data[7]),
    .a_ready,.b_ready,.d_ready,.req_ready,
    .resp_valid,.resp_tag_id(resp_tag),.resp_data_0(resp_word[0]),.resp_data_1(resp_word[1]),.resp_data_2(resp_word[2]),
    .resp_data_3(resp_word[3]),.resp_data_4(resp_word[4]),.resp_data_5(resp_word[5]),.resp_data_6(resp_word[6]),
    .resp_data_7(resp_word[7]),.resp_total_rows(resp_rows),.resp_last(resp_last));
endmodule
