// One registered hop. Admission permits one packet per lane; no link FIFOs
// or combinational ready chains. Request and response lanes progress independently.
module mixed_router import mixed_packet::*; #(parameter int ID=0, COLS=5)(
  input logic clock, reset, inject, input packet_t injected,
  input logic [3:0] arrived, input packet_t neighbors[4],
  output logic occupied, output packet_t held, output logic [3:0] send,
  output logic deliver, input logic take
);
  always_comb begin
    send = '0;
    deliver = occupied && held.target == 5'(ID);
    if (occupied && !deliver) begin
      if (int'(held.target) % COLS < ID % COLS) send[0]=1;
      else if (int'(held.target) % COLS > ID % COLS) send[1]=1;
      else if (int'(held.target) / COLS < ID / COLS) send[2]=1;
      else send[3]=1;
    end
  end
  always_ff @(posedge clock) begin
    if (reset) occupied <= 0;
    else if (inject) begin occupied <= 1; held <= injected; held.origin <= 5'(ID); end
    else if (|arrived) begin
      occupied <= 1;
      for (int p=0; p<4; p++) if (arrived[p]) held <= neighbors[p];
    end else if (|send || (deliver && take)) occupied <= 0;
  end
endmodule
