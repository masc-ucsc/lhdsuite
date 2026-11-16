// A tile's source ID is local. The mesh origin selects the physical copy; it
// is independent of the one-bit hartid port of these two Chisel configurations.
module mixed_cpu import mixed_packet::*; #(
  parameter bit IS_BOOM=0, parameter int ID=0, HOST=19, ACC=16
)(input logic clock, reset, output logic txv, input logic txr, output packet_t tx,
  input logic rxv, output logic rxr, input packet_t rx);
  logic av, ar, cv, cr, ev, er, dr, br;
  logic [3:0] aop, asz, csz;
  logic [2:0] ap, cp, asrc, csrc, cop, sink;
  logic [31:0] aa, ca;
  logic [63:0] ad, cd;
  logic [7:0] am;
  logic ac, cc;
  // A CPU may raise C or E while an earlier A is waiting for mesh service.
  // Register the selected beat so the packet offered to the router stays stable.
  packet_t selected;
  logic buffered;
  assign ar=!reset&&!buffered&&!cv&&!ev;
  assign cr=!reset&&!buffered&&!ev;
  assign er=!reset&&!buffered;
  assign txv=buffered;
  always_ff @(posedge clock) begin
    if(reset) buffered<=0;
    else if(buffered) begin
      if(txr) buffered<=0;
    end else if(av||cv||ev) begin
      buffered<=1; tx<=selected;
    end
  end
  assign rxr=rx.ch==D ? dr : rx.ch==B && IS_BOOM && br;
  always_comb begin
    selected='0; selected.target=5'(HOST);
    if (ev) begin selected.ch=E; selected.sink=sink; end
    else if (cv) begin selected.ch=C; selected.opcode={1'b0,cop}; selected.param=cp; selected.size=csz; selected.tl_source=csrc;
      selected.addr=ca; selected.data=cd; selected.corrupt=cc; end
    else begin selected.ch=A; selected.opcode=aop; selected.param=ap; selected.size=asz; selected.tl_source=asrc;
      selected.addr=aa; selected.mask=am; selected.data=ad; selected.corrupt=ac;
      if(acc_address(aa)) begin
        selected.target=5'(ACC);
        if(!IS_BOOM && aa[2]) begin selected.data=ad<<32; selected.mask=am<<4; end
      end
    end
  end
  if (IS_BOOM) begin : boom
    wire [2:0] ao;
    assign aop={1'b0,ao};
    BoomTile core(.clock, .reset, .auto_hartid_in(1'(ID)),
      .auto_int_local_in_0_0(1'b0),.auto_int_local_in_1_0(1'b0),.auto_int_local_in_1_1(1'b0),
      .auto_int_local_in_2_0(1'b0),.auto_int_local_in_3_0(1'b0),
      .auto_buffer_out_a_valid(av),.auto_buffer_out_a_ready(ar),.auto_buffer_out_a_bits_opcode(ao),
      .auto_buffer_out_a_bits_param(ap),.auto_buffer_out_a_bits_size(asz),.auto_buffer_out_a_bits_source(asrc),
      .auto_buffer_out_a_bits_address(aa),.auto_buffer_out_a_bits_mask(am),.auto_buffer_out_a_bits_data(ad),.auto_buffer_out_a_bits_corrupt(ac),
      .auto_buffer_out_b_valid(rxv && rx.ch==B),.auto_buffer_out_b_ready(br),.auto_buffer_out_b_bits_opcode(rx.opcode[2:0]),
      .auto_buffer_out_b_bits_param(rx.param[1:0]),.auto_buffer_out_b_bits_size(rx.size),.auto_buffer_out_b_bits_source(rx.tl_source),
      .auto_buffer_out_b_bits_address(rx.addr),.auto_buffer_out_b_bits_mask(rx.mask),.auto_buffer_out_b_bits_data(rx.data),.auto_buffer_out_b_bits_corrupt(rx.corrupt),
      .auto_buffer_out_c_valid(cv),.auto_buffer_out_c_ready(cr),.auto_buffer_out_c_bits_opcode(cop),.auto_buffer_out_c_bits_param(cp),
      .auto_buffer_out_c_bits_size(csz),.auto_buffer_out_c_bits_source(csrc),.auto_buffer_out_c_bits_address(ca),.auto_buffer_out_c_bits_data(cd),.auto_buffer_out_c_bits_corrupt(cc),
      .auto_buffer_out_d_valid(rxv && rx.ch==D),.auto_buffer_out_d_ready(dr),.auto_buffer_out_d_bits_opcode(rx.opcode[2:0]),
      .auto_buffer_out_d_bits_param(rx.param[1:0]),.auto_buffer_out_d_bits_size(rx.size),.auto_buffer_out_d_bits_source(rx.tl_source),
      .auto_buffer_out_d_bits_sink(rx.sink),.auto_buffer_out_d_bits_denied(rx.denied),.auto_buffer_out_d_bits_data(rx.data),.auto_buffer_out_d_bits_corrupt(rx.corrupt),
      .auto_buffer_out_e_valid(ev),.auto_buffer_out_e_ready(er),.auto_buffer_out_e_bits_sink(sink));
  end else begin : rocket
    wire src; wire [3:0] mask; wire [31:0] data;
    assign asrc={2'b0,src}; assign am={4'b0,mask}; assign ad={32'b0,data};
    assign {cv,ev,br,csz,cp,csrc,cop,sink,ca,cd,cc}='0;
    RocketTile core(.clock,.reset,.auto_hartid_in(1'(ID)),.auto_int_local_in_0_0(1'b0),.auto_int_local_in_1_0(1'b0),
      .auto_int_local_in_1_1(1'b0),.auto_int_local_in_2_0(1'b0),
      .auto_buffer_in_a_valid(1'b0),.auto_buffer_in_a_bits_opcode('0),.auto_buffer_in_a_bits_param('0),.auto_buffer_in_a_bits_size('0),
      .auto_buffer_in_a_bits_source('0),.auto_buffer_in_a_bits_address('0),.auto_buffer_in_a_bits_mask('0),
      .auto_buffer_in_a_bits_data('0),.auto_buffer_in_a_bits_corrupt(1'b0),.auto_buffer_in_d_ready(1'b1),
      .auto_buffer_out_a_valid(av),.auto_buffer_out_a_ready(ar),.auto_buffer_out_a_bits_opcode(aop),.auto_buffer_out_a_bits_param(ap),
      .auto_buffer_out_a_bits_size(asz),.auto_buffer_out_a_bits_source(src),.auto_buffer_out_a_bits_address(aa),
      .auto_buffer_out_a_bits_mask(mask),.auto_buffer_out_a_bits_data(data),
      .auto_buffer_out_d_valid(rxv && rx.ch==D),.auto_buffer_out_d_ready(dr),.auto_buffer_out_d_bits_opcode(rx.opcode),
      .auto_buffer_out_d_bits_param(rx.param[1:0]),.auto_buffer_out_d_bits_size(rx.size),.auto_buffer_out_d_bits_source(rx.tl_source[0]),
      .auto_buffer_out_d_bits_sink(rx.sink[0]),.auto_buffer_out_d_bits_denied(rx.denied),
      .auto_buffer_out_d_bits_data(rx.origin==5'(ACC) && rx.addr[2] ? rx.data[63:32] : rx.data[31:0]),.auto_buffer_out_d_bits_corrupt(rx.corrupt));
    assign ac=0; // This Rocket master has no A.corrupt port.
  end
endmodule
