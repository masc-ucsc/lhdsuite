// Single-beat Get/Put MMIO window onto the selected 8x8 TPU's real 64 x 256-bit accumulator.
module mixed_acc import mixed_packet::*; (
  input logic clock, reset, input logic rxv, output logic rxr, input packet_t rx,
  output logic txv, input logic txr, output packet_t tx);
  typedef enum logic [1:0] {IDLE, READING, REPLY} state_t;
  state_t state;
  packet_t answer;
  logic cmd_ok, get, put, wr_ready, rd_ready, rd_valid;
  logic [63:0] rd_data[4];
  assign get=rx.opcode==4; assign put=rx.opcode==0 || rx.opcode==1;
  assign cmd_ok=rx.ch==A && acc_address(rx.addr) && !rx.corrupt && rx.size<=3
                && (rx.addr & ((32'd1<<rx.size)-1))==0 && (get || put);
  assign rxr=state==IDLE && (!cmd_ok || (get ? rd_ready : wr_ready));
  assign txv=state==REPLY;
  assign tx=answer;
  always_ff @(posedge clock) begin
    if(reset) state<=IDLE;
    else case(state)
      IDLE: if(rxv && rxr) begin
        answer<='0; answer.ch<=D; answer.target<=rx.origin; answer.tl_source<=rx.tl_source;
        answer.opcode<=get ? 1 : 0; answer.size<=rx.size; answer.addr<=rx.addr; answer.denied<=!cmd_ok;
        state<=cmd_ok && get ? READING : REPLY;
      end
      READING: if(rd_valid) begin answer.data<=rd_data[answer.addr[4:3]]; state<=REPLY; end
      REPLY: if(txr) state<=IDLE;
      default: state<=IDLE;
    endcase
  end
  GemminiSimTop gemmini(.clock,.reset,.a_valid(1'b0),.a_bits('0),.b_valid(1'b0),.b_bits('0),.d_valid(1'b0),.d_bits('0),
    .req_valid(1'b0),.req_tag_id('0),.req_dataflow('0),.req_propagate('0),.req_shift('0),
    .req_a_transpose('0),.req_bd_transpose('0),.req_total_rows('0),.req_flush('0),
    .wr_valid(state==IDLE && rxv && cmd_ok && put),.wr_addr(rx.addr[10:5]),
    .wr_data_0(rx.data),.wr_data_1(rx.data),.wr_data_2(rx.data),.wr_data_3(rx.data),.wr_acc(1'b0),
    .wr_mask({24'b0,rx.mask} << (8*rx.addr[4:3])),.wr_ready,
    .rd_valid(state==IDLE && rxv && cmd_ok && get),.rd_addr(rx.addr[10:5]),.rd_scale('0),.rd_act('0),.rd_full(1'b1),
    .rd_fromDMA(1'b1),.rd_req_ready(rd_ready),.rd_resp_ready(state==READING),.rd_resp_valid(rd_valid),
    .rd_data_0(rd_data[0]),.rd_data_1(rd_data[1]),.rd_data_2(rd_data[2]),.rd_data_3(rd_data[3]));
endmodule
