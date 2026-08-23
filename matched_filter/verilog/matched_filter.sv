// Streaming one-dimensional SAR matched filter. This is an independent
// implementation of the contract in ../pyrope/matched_filter.prp.
module matched_filter #(
  parameter integer SIZE       = 64,
  parameter integer LOG2_SIZE  = 6,
  parameter integer MULT_WIDTH = 4
)(
  input                            clock,
  input                            reset,
  input  signed [7:0]             x,
  input  signed [7:0]             ref_in,
  input                            ref_load,
  output signed [MULT_WIDTH+LOG2_SIZE-1:0] y,
  output                           y_valid
);
  localparam integer SUM_WIDTH = MULT_WIDTH + LOG2_SIZE;

  // The x and reference streams have independent shift enables.
  wire signed [7:0] xs   [0:SIZE];
  wire signed [7:0] refs [0:SIZE];
  assign xs[0]   = x;
  assign refs[0] = ref_in;

  // Level zero contains sign-extended, MSB-retained products. Later levels
  // are registered: every physical node has distinct storage.
  wire [SUM_WIDTH*SIZE-1:0] level [0:LOG2_SIZE];

  genvar i, lvl, j;
  generate
    for (i = 0; i < SIZE; i = i + 1) begin : taps
      tap t(.clock(clock), .reset(reset),
            .x_in(xs[i]), .ref_in(refs[i]), .ref_load(ref_load),
            .x_out(xs[i+1]), .ref_out(refs[i+1]));

      if (MULT_WIDTH >= 8) begin : full_operand_product
        wire signed [15:0] full_product;
        wire signed [MULT_WIDTH-1:0] product;
        assign full_product = xs[i+1] * refs[i+1];
        assign product = full_product[16-MULT_WIDTH +: MULT_WIDTH];
        assign level[0][SUM_WIDTH*i +: SUM_WIDTH] =
          {{LOG2_SIZE{product[MULT_WIDTH-1]}}, product};
      end else begin : narrow_operand_product
        wire signed [MULT_WIDTH-1:0] x_msb;
        wire signed [MULT_WIDTH-1:0] ref_msb;
        wire signed [2*MULT_WIDTH-1:0] full_product;
        wire signed [MULT_WIDTH-1:0] product;
        assign x_msb = xs[i+1][8-MULT_WIDTH +: MULT_WIDTH];
        assign ref_msb = refs[i+1][8-MULT_WIDTH +: MULT_WIDTH];
        assign full_product = x_msb * ref_msb;
        assign product = full_product[MULT_WIDTH +: MULT_WIDTH];
        assign level[0][SUM_WIDTH*i +: SUM_WIDTH] =
          {{LOG2_SIZE{product[MULT_WIDTH-1]}}, product};
      end
    end

    for (lvl = 0; lvl < LOG2_SIZE; lvl = lvl + 1) begin : levels
      for (j = 0; j < (SIZE >> (lvl + 1)); j = j + 1) begin : nodes
        add_node #(.SW(SUM_WIDTH)) n(
          .clock(clock), .reset(reset),
          .a(level[lvl][SUM_WIDTH*(2*j) +: SUM_WIDTH]),
          .b(level[lvl][SUM_WIDTH*(2*j+1) +: SUM_WIDTH]),
          .s(level[lvl+1][SUM_WIDTH*j +: SUM_WIDTH])
        );
      end
      if ((SIZE >> (lvl + 1)) < SIZE) begin : pad
        assign level[lvl+1][SUM_WIDTH*SIZE-1 :
                            SUM_WIDTH*(SIZE >> (lvl + 1))] =
          {(SUM_WIDTH*(SIZE - (SIZE >> (lvl + 1)))){1'b0}};
      end
    end
  endgenerate

  // One validity bit per registered adder level. A reference load flushes
  // every in-flight result and suppresses y_valid immediately.
  reg [LOG2_SIZE-1:0] valid_pipe;
  always @(posedge clock) begin
    if (reset || ref_load)
      valid_pipe <= {LOG2_SIZE{1'b0}};
    else
      valid_pipe <= (valid_pipe << 1) |
                    {{(LOG2_SIZE-1){1'b0}}, 1'b1};
  end

  assign y_valid = !ref_load && valid_pipe[LOG2_SIZE-1];
  assign y = y_valid ? level[LOG2_SIZE][SUM_WIDTH-1:0] : {SUM_WIDTH{1'b0}};
endmodule
