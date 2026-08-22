// Copyright (c) 2018 - 2019 ETH Zurich, University of Bologna
// All rights reserved.
//
// This code is under development and not yet released to the public.
// Until it is released, the code is under the copyright of ETH Zurich and
// the University of Bologna, and may contain confidential and/or unpublished
// work. Any reuse/redistribution is strictly forbidden without written
// permission from ETH Zurich.
//
// Bug fixes and contributions will eventually be released under the
// SolderPad open hardware license in the context of the PULP platform
// (http://www.pulp-platform.org), under the copyright of ETH Zurich and the
// University of Bologna.

/// A trailing zero counter / leading zero counter.
/// Set MODE to 0 for trailing zero counter => cnt_o is the number of trailing zeros (from the LSB)
/// Set MODE to 1 for leading zero counter  => cnt_o is the number of leading zeros  (from the MSB)
/// If the input does not contain a zero, `empty_o` is asserted. Additionally `cnt_o` contains
/// the maximum number of zeros - 1. For example:
///   in_i = 000_0000, empty_o = 1, cnt_o = 6 (mode = 0)
///   in_i = 000_0001, empty_o = 0, cnt_o = 0 (mode = 0)
///   in_i = 000_1000, empty_o = 0, cnt_o = 3 (mode = 0)
/// Furthermore, this unit contains a more efficient implementation for Verilator (simulation only).
/// This speeds up simulation significantly.
module lzc #(
  /// The width of the input vector.
  parameter int unsigned WIDTH = 2,
  /// Mode selection: 0 -> trailing zero, 1 -> leading zero
  parameter bit          MODE  = 1'b0,
  /// Dependent parameter. Do **not** change!
  ///
  /// Width of the output signal with the zero count.
  parameter int unsigned CNT_WIDTH = cf_math_pkg::idx_width(WIDTH)
) (
  /// Input vector to be counted.
  input  logic [WIDTH-1:0]     in_i,
  /// Count of the leading / trailing zeros.
  output logic [CNT_WIDTH-1:0] cnt_o,
  /// Counter is empty: Asserted if all bits in in_i are zero.
  output logic                 empty_o
);

  if (WIDTH == 1) begin : gen_degenerate_lzc

    assign cnt_o[0] = !in_i[0];
    assign empty_o = !in_i[0];

  end else begin : gen_lzc

    localparam int unsigned NumLevels = $clog2(WIDTH);

    // pragma translate_off
    initial begin
      assert(WIDTH > 0) else $fatal(1, "input must be at least one bit wide");
    end
    // pragma translate_on

    logic [WIDTH-1:0] in_tmp;

    // reverse vector if required
    always_comb begin : flip_vector
      for (int unsigned i = 0; i < WIDTH; i++) begin
        in_tmp[i] = (MODE) ? in_i[WIDTH-1-i] : in_i[i];
      end
    end

    // The reduction tree this replaces was written as continuous assigns over
    // ONE `sel_nodes` / `index_nodes` array, where level L reads the slices
    // level L+1 writes. Continuous assigns are order-free, so that is perfectly
    // legal Verilog -- but a front end that linearizes them into ordered
    // statements has to pick an order, and the net is both read and written by
    // the same drivers, so there is no per-net ordering to pick. LiveHD's
    // --reader slang silently emitted the ROOT first and folded the whole tree
    // to X; it now refuses with `unsupported-driver-order`. (Reversing the
    // generate loop does not help: the sort reorders the root forward again on
    // its `sel_nodes` edges.)
    //
    // With no bit set, the tree took every `else` branch down to its RIGHTMOST
    // leaf, so the answer is that leaf's index_lut entry -- which is WIDTH-1
    // only when WIDTH is a power of two. For WIDTH=5 the rightmost leaf is out
    // of range and the tree answers 0. Derive it rather than assume it.
    localparam int unsigned RightLeaf = 2 ** NumLevels - 2;         // its low input index
    localparam int unsigned EmptyCnt  = (RightLeaf < WIDTH - 1)  ? RightLeaf + 1  // g_reduce -> lut[2k+1]
                                      : (RightLeaf == WIDTH - 1) ? RightLeaf      // g_base   -> lut[2k]
                                                                 : 0;             // g_out_of_range -> '0

    // One procedural block instead. It reads only `in_tmp` and writes only the
    // outputs, so nothing is both read and written, and a process orders its
    // own statements by definition. Last-write-wins over a descending scan
    // leaves `cnt_o` at the LOWEST set index of `in_tmp`, which is the same
    // function the tree computed; `EmptyCnt` above reproduces its all-zero
    // answer. LEC-proven against the original tree for WIDTH 2,3,5,6,7,8,9,12,16
    // x MODE 0,1.
    always_comb begin : lzc_scan
      cnt_o   = CNT_WIDTH'(EmptyCnt);
      empty_o = ~(|in_tmp);
      for (int unsigned i = WIDTH; i > 0; i--) begin
        if (in_tmp[i-1]) begin
          cnt_o = CNT_WIDTH'(i - 1);
        end
      end
    end

  end : gen_lzc

endmodule : lzc
