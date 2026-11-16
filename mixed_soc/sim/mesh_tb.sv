// Small stand-alone network bench; all sources contend in every round.
module mixed_mesh_tb;
  import mixed_packet::*;
  import mixed_layout::*;
  bit clock=0, reset=1; always #1 clock=~clock;
  integer phase=0, cycles=0, total=0;
  integer injected_at[N];
  logic [N-1:0] txv, txr, rxv, rxr, sent, received, stalled;
  packet_t tx[N], rx[N], blocked[N];
  mixed_mesh dut(.*);

  function automatic packet_t probe(int src, int round);
    packet_t p;
    p='0; p.origin=5'(src); p.target=round==N ? 5'(HOST) : 5'((src+round)%N);
    p.ch=channel_t'(round%5); p.opcode=4'(round); p.param=3'(src); p.size=4'(src+round);
    p.tl_source=3'(src+round); p.sink=3'(round); p.addr=32'hff000000 | (src<<8) | round;
    p.mask=8'(src ^ round); p.data=64'hdecaf00d12345678 ^ (64'(src)<<32) ^ 64'(round);
    p.corrupt=src[0]; p.denied=round[0];
    return p;
  endfunction
  function automatic int mag(int v); return v<0 ? -v : v; endfunction
  for(genvar i=0;i<N;i++) begin
    always_comb begin
      tx[i]=probe(i,phase);
      tx[i].origin='1; // A sender cannot forge its fabric source address.
      txv[i]=!reset && !sent[i];
      rxr[i]=(cycles+i)%6>=3;
    end
  end
  always @(posedge clock) begin
    if(reset) begin sent<='0; received<='0; stalled<='0; end
    else begin
      cycles<=cycles+1;
      if(cycles>10000) $fatal(1,"mesh deadlock");
      for(int i=0;i<N;i++) begin
        if(txv[i] && txr[i]) begin sent[i]<=1; injected_at[i]<=cycles; end
        if(stalled[i] && (!rxv[i] || rx[i]!==blocked[i])) $fatal(1,"packet changed during backpressure");
        stalled[i]<=rxv[i] && !rxr[i]; blocked[i]<=rx[i];
        if(rxv[i]) begin
          int src, distance;
          src=int'(rx[i].origin);
          if(src>=N || rx[i].target!=5'(i) || rx[i]!==probe(src,phase) || !sent[src] || received[src])
            $fatal(1,"misrouted, duplicate, or corrupted packet: round=%0d src=%0d dest=%0d",phase,src,i);
          distance=mag(src%COLS - i%COLS)+mag(src/COLS - i/COLS);
          if(!stalled[i] && cycles-injected_at[src]!=1+distance) $fatal(1,"wrong hop count %0d -> %0d", src,i);
          if(rxr[i]) begin received[src]<=1; total<=total+1; end
        end
      end
      if(&received) begin
        if (sent!='1) $fatal(1,"missing injection");
        if(phase==N) begin
          if(total!=N*(N+1)) $fatal(1,"missing deliveries");
          $display("PASS: %0d ordered endpoint pairs plus %0d simultaneous requests to external port, %0d packets",N*N,N,total);
          $finish;
        end
        phase<=phase+1; sent<='0; received<='0;
      end
    end
  end
  initial begin repeat(4) @(negedge clock); reset=0; end
endmodule
