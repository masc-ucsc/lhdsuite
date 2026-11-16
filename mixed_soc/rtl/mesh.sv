// wiring.svh is generated from exactly the tile edges used by floorplan.py.
module mixed_mesh import mixed_packet::*; import mixed_layout::*; (
  input logic clock, reset, input logic [N-1:0] txv, output logic [N-1:0] txr, input packet_t tx[N],
  output logic [N-1:0] rxv, input logic [N-1:0] rxr, output packet_t rx[N]);
  logic [N-1:0] used;
  logic [3:0] send[N], arrived[N];
  packet_t neighbors[N][4];
  logic [4:0] cursor;
  integer grant;
  always_comb begin
    grant=-1; txr='0;
    for(int i=0;i<N;i++) begin
      int k; k=(int'(cursor)+i)%N;
      if(!reset && used=='0 && grant<0 && txv[k] && int'(tx[k].target)<N) grant=k;
    end
    if(grant>=0) txr[grant]=1'b1;
  end
  always_ff @(posedge clock)
    if(reset) cursor<=0;
    else if(grant>=0) cursor<=5'((grant+1)%N);
  for(genvar i=0;i<N;i++) begin: tile
    mixed_router #(.ID(i),.COLS(COLS)) r(.clock,.reset,.inject(txr[i]),.injected(tx[i]),.arrived(arrived[i]),
      .neighbors(neighbors[i]),.occupied(used[i]),.held(rx[i]),.send(send[i]),.deliver(rxv[i]),.take(rxr[i]));
  end
  `include "wiring.svh"
endmodule
