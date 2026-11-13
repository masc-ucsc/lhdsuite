// The suite's bitcoin configuration. Every other file in this directory is
// vendored VERBATIM from LogikBench (see ../README.md); this wrapper is the one
// hand-written file, and it exists only to pin NENGINES.
//
// Upstream defaults to NENGINES = 128 (~1.3M cells), a synthesis-size point:
// 128 SHA-256 cores make every simulated cycle 128x the work and every compile
// or LEC scenario 128x the graph, for no additional coverage — the lanes are
// identical instances differing only in their nonce offset. Sixteen lanes keep
// the multi-lane arbitration (lowest index wins) and the interleaved nonce
// stride real while the benchmark stays in the size class of the other cores.
module bitcoin_top (
   input  wire         clk,
   input  wire         reset_n,
   input  wire         start,
   input  wire [639:0] header,
   input  wire [255:0] target,
   input  wire [31:0]  nonce_base,
   output wire         found,
   output wire [31:0]  golden_nonce,
   output wire         busy
   );

   bitcoin #(.NENGINES(16)) u_miner
     (.clk          (clk),
      .reset_n      (reset_n),
      .start        (start),
      .header       (header),
      .target       (target),
      .nonce_base   (nonce_base),
      .found        (found),
      .golden_nonce (golden_nonce),
      .busy         (busy));

endmodule
