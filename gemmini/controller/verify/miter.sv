// Evaluate both clock phases. Primary inputs change on the falling edge.
// Two rising edges of reset establish the initial state.
module miter;
  reg clock = 0;
  reg [2:0] ticks = 0;
  (* anyseq *) reg [26:0] inputs;
  reg [26:0] held = 0;
  always @($global_clock) begin
    clock <= !clock;
    if (clock) held <= inputs;
    if (ticks < 6) ticks <= ticks + 1'b1;
  end
  wire reset = ticks < 4 || held[25];
  wire [7:0] io_bytes = held[7:0], io_returned_bytes = held[15:8];
  wire [3:0] io_tag = held[19:16];
  wire io_gate_write = held[20], io_gate_value = held[21], io_alloc = held[22];
  wire io_returned = held[23], io_returned_id = held[24], io_accept = held[26];
  wire [8:0] gold, impl;
  GatedTracker reference(.io_ready(gold[8]), .io_id(gold[7]), .io_valid(gold[6]),
    .io_out_id(gold[5]), .io_out_tag(gold[4:1]), .io_busy(gold[0]), .*);
  Impl_GatedTracker guarded(.io_ready(impl[8]), .io_id(impl[7]), .io_valid(impl[6]),
    .io_out_id(impl[5]), .io_out_tag(impl[4:1]), .io_busy(impl[0]), .*);
  always @* if (ticks >= 4) begin
`ifdef MUTATE_COMPLETION
    // Change a tag bit only when a completion is actually observable.
    assert(gold == (impl ^ {7'b0, impl[6], 1'b0}));
`else
    assert(gold == impl);
`endif
  end
endmodule
