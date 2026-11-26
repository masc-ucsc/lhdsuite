module DMACommandTracker(
  input        clock,
  input        reset,
  input        io_alloc_valid, // @[src/main/scala/DMACommandTracker.scala 12:14]
  output       io_alloc_ready, // @[src/main/scala/DMACommandTracker.scala 12:14]
  input  [3:0] io_alloc_bits_tag, // @[src/main/scala/DMACommandTracker.scala 12:14]
  input  [7:0] io_alloc_bits_bytes_to_read, // @[src/main/scala/DMACommandTracker.scala 12:14]
  output       io_alloc_bits_cmd_id, // @[src/main/scala/DMACommandTracker.scala 12:14]
  input        io_request_returned_valid, // @[src/main/scala/DMACommandTracker.scala 12:14]
  input  [7:0] io_request_returned_bits_bytes_read, // @[src/main/scala/DMACommandTracker.scala 12:14]
  input        io_request_returned_bits_cmd_id, // @[src/main/scala/DMACommandTracker.scala 12:14]
  input        io_cmd_completed_ready, // @[src/main/scala/DMACommandTracker.scala 12:14]
  output       io_cmd_completed_valid, // @[src/main/scala/DMACommandTracker.scala 12:14]
  output       io_cmd_completed_bits_cmd_id, // @[src/main/scala/DMACommandTracker.scala 12:14]
  output [3:0] io_cmd_completed_bits_tag, // @[src/main/scala/DMACommandTracker.scala 12:14]
  output       io_busy // @[src/main/scala/DMACommandTracker.scala 12:14]
);
`ifdef RANDOMIZE_REG_INIT
  reg [31:0] _RAND_0;
  reg [31:0] _RAND_1;
  reg [31:0] _RAND_2;
  reg [31:0] _RAND_3;
  reg [31:0] _RAND_4;
  reg [31:0] _RAND_5;
`endif // RANDOMIZE_REG_INIT
  reg  cmds_0_valid; // @[src/main/scala/DMACommandTracker.scala 61:17]
  reg [3:0] cmds_0_tag; // @[src/main/scala/DMACommandTracker.scala 61:17]
  reg [7:0] cmds_0_bytes_left; // @[src/main/scala/DMACommandTracker.scala 61:17]
  reg  cmds_1_valid; // @[src/main/scala/DMACommandTracker.scala 61:17]
  reg [3:0] cmds_1_tag; // @[src/main/scala/DMACommandTracker.scala 61:17]
  reg [7:0] cmds_1_bytes_left; // @[src/main/scala/DMACommandTracker.scala 61:17]
  wire  _next_empty_alloc_T = ~cmds_0_valid; // @[src/main/scala/DMACommandTracker.scala 64:85]
  wire  _next_empty_alloc_T_1 = ~cmds_1_valid; // @[src/main/scala/DMACommandTracker.scala 64:85]
  wire  next_empty_alloc = _next_empty_alloc_T ? 1'h0 : _next_empty_alloc_T_1; // @[src/main/scala/chisel3/util/Mux.scala 141:16]
  wire  _cmd_completed_id_T_1 = cmds_0_valid & cmds_0_bytes_left == 8'h0; // @[src/main/scala/DMACommandTracker.scala 72:16]
  wire  _cmd_completed_id_T_3 = cmds_1_valid & cmds_1_bytes_left == 8'h0; // @[src/main/scala/DMACommandTracker.scala 72:16]
  wire  cmd_completed_id = _cmd_completed_id_T_1 ? 1'h0 : _cmd_completed_id_T_3; // @[src/main/scala/chisel3/util/Mux.scala 141:16]
  wire  _T = io_alloc_valid & io_alloc_ready; // @[src/main/scala/DMACommandTracker.scala 27:40]
  wire  _GEN_2 = ~next_empty_alloc | cmds_0_valid; // @[src/main/scala/DMACommandTracker.scala 61:17 79:{34,34}]
  wire  _GEN_3 = next_empty_alloc | cmds_1_valid; // @[src/main/scala/DMACommandTracker.scala 61:17 79:{34,34}]
  wire [7:0] _GEN_6 = ~next_empty_alloc ? io_alloc_bits_bytes_to_read : cmds_0_bytes_left; // @[src/main/scala/DMACommandTracker.scala 61:17 81:{39,39}]
  wire [7:0] _GEN_7 = next_empty_alloc ? io_alloc_bits_bytes_to_read : cmds_1_bytes_left; // @[src/main/scala/DMACommandTracker.scala 61:17 81:{39,39}]
  wire  _GEN_8 = _T ? _GEN_2 : cmds_0_valid; // @[src/main/scala/DMACommandTracker.scala 61:17 78:26]
  wire  _GEN_9 = _T ? _GEN_3 : cmds_1_valid; // @[src/main/scala/DMACommandTracker.scala 61:17 78:26]
  wire [7:0] _GEN_12 = _T ? _GEN_6 : cmds_0_bytes_left; // @[src/main/scala/DMACommandTracker.scala 61:17 78:26]
  wire [7:0] _GEN_13 = _T ? _GEN_7 : cmds_1_bytes_left; // @[src/main/scala/DMACommandTracker.scala 61:17 78:26]
  wire [7:0] _GEN_15 = io_request_returned_bits_cmd_id ? cmds_1_bytes_left : cmds_0_bytes_left; // @[src/main/scala/DMACommandTracker.scala 86:{56,56}]
  wire [7:0] _cmds_bytes_left_T_1 = _GEN_15 - io_request_returned_bits_bytes_read; // @[src/main/scala/DMACommandTracker.scala 86:56]
  wire  _GEN_19 = io_request_returned_bits_cmd_id ? cmds_1_valid : cmds_0_valid; // @[src/main/scala/DMACommandTracker.scala 88:{11,11}]
  wire  _T_8 = io_cmd_completed_ready & io_cmd_completed_valid; // @[src/main/scala/chisel3/util/Decoupled.scala 57:35]
  wire  _GEN_29 = io_request_returned_valid & ~reset; // @[src/main/scala/DMACommandTracker.scala 88:11]
  assign io_alloc_ready = ~(cmds_0_valid & cmds_1_valid); // @[src/main/scala/DMACommandTracker.scala 66:21]
  assign io_alloc_bits_cmd_id = _next_empty_alloc_T ? 1'h0 : _next_empty_alloc_T_1; // @[src/main/scala/chisel3/util/Mux.scala 141:16]
  assign io_cmd_completed_valid = _cmd_completed_id_T_1 | _cmd_completed_id_T_3; // @[src/main/scala/DMACommandTracker.scala 74:91]
  assign io_cmd_completed_bits_cmd_id = _cmd_completed_id_T_1 ? 1'h0 : _cmd_completed_id_T_3; // @[src/main/scala/chisel3/util/Mux.scala 141:16]
  assign io_cmd_completed_bits_tag = cmd_completed_id ? cmds_1_tag : cmds_0_tag; // @[src/main/scala/DMACommandTracker.scala 76:{29,29}]
  assign io_busy = cmds_0_valid | cmds_1_valid; // @[src/main/scala/DMACommandTracker.scala 69:34]
  always @(posedge clock) begin
    if (reset) begin // @[src/main/scala/DMACommandTracker.scala 96:23]
      cmds_0_valid <= 1'h0; // @[src/main/scala/DMACommandTracker.scala 56:13]
    end else if (_T_8) begin // @[src/main/scala/DMACommandTracker.scala 92:32]
      if (~io_cmd_completed_bits_cmd_id) begin // @[src/main/scala/DMACommandTracker.scala 93:46]
        cmds_0_valid <= 1'h0; // @[src/main/scala/DMACommandTracker.scala 93:46]
      end else begin
        cmds_0_valid <= _GEN_8;
      end
    end else begin
      cmds_0_valid <= _GEN_8;
    end
    if (_T) begin // @[src/main/scala/DMACommandTracker.scala 78:26]
      if (~next_empty_alloc) begin // @[src/main/scala/DMACommandTracker.scala 80:32]
        cmds_0_tag <= io_alloc_bits_tag; // @[src/main/scala/DMACommandTracker.scala 80:32]
      end
    end
    if (io_request_returned_valid) begin // @[src/main/scala/DMACommandTracker.scala 84:35]
      if (~io_request_returned_bits_cmd_id) begin // @[src/main/scala/DMACommandTracker.scala 86:29]
        cmds_0_bytes_left <= _cmds_bytes_left_T_1; // @[src/main/scala/DMACommandTracker.scala 86:29]
      end else begin
        cmds_0_bytes_left <= _GEN_12;
      end
    end else begin
      cmds_0_bytes_left <= _GEN_12;
    end
    if (reset) begin // @[src/main/scala/DMACommandTracker.scala 96:23]
      cmds_1_valid <= 1'h0; // @[src/main/scala/DMACommandTracker.scala 56:13]
    end else if (_T_8) begin // @[src/main/scala/DMACommandTracker.scala 92:32]
      if (io_cmd_completed_bits_cmd_id) begin // @[src/main/scala/DMACommandTracker.scala 93:46]
        cmds_1_valid <= 1'h0; // @[src/main/scala/DMACommandTracker.scala 93:46]
      end else begin
        cmds_1_valid <= _GEN_9;
      end
    end else begin
      cmds_1_valid <= _GEN_9;
    end
    if (_T) begin // @[src/main/scala/DMACommandTracker.scala 78:26]
      if (next_empty_alloc) begin // @[src/main/scala/DMACommandTracker.scala 80:32]
        cmds_1_tag <= io_alloc_bits_tag; // @[src/main/scala/DMACommandTracker.scala 80:32]
      end
    end
    if (io_request_returned_valid) begin // @[src/main/scala/DMACommandTracker.scala 84:35]
      if (io_request_returned_bits_cmd_id) begin // @[src/main/scala/DMACommandTracker.scala 86:29]
        cmds_1_bytes_left <= _cmds_bytes_left_T_1; // @[src/main/scala/DMACommandTracker.scala 86:29]
      end else begin
        cmds_1_bytes_left <= _GEN_13;
      end
    end else begin
      cmds_1_bytes_left <= _GEN_13;
    end
    `ifndef SYNTHESIS
    `ifdef PRINTF_COND
      if (`PRINTF_COND) begin
    `endif
        if (io_request_returned_valid & ~reset & ~_GEN_19) begin
          $fwrite(32'h80000002,"Assertion failed\n    at DMACommandTracker.scala:88 assert(cmds(cmd_id).valid)\n"); // @[src/main/scala/DMACommandTracker.scala 88:11]
        end
    `ifdef PRINTF_COND
      end
    `endif
    `endif // SYNTHESIS
    `ifndef SYNTHESIS
    `ifdef STOP_COND
      if (`STOP_COND) begin
    `endif
        if (io_request_returned_valid & ~reset & ~_GEN_19) begin
          $fatal; // @[src/main/scala/DMACommandTracker.scala 88:11]
        end
    `ifdef STOP_COND
      end
    `endif
    `endif // SYNTHESIS
    `ifndef SYNTHESIS
    `ifdef PRINTF_COND
      if (`PRINTF_COND) begin
    `endif
        if (_GEN_29 & ~(_GEN_15 >= io_request_returned_bits_bytes_read)) begin
          $fwrite(32'h80000002,
            "Assertion failed\n    at DMACommandTracker.scala:89 assert(cmds(cmd_id).bytes_left >= io.request_returned.bits.bytes_read)\n"
            ); // @[src/main/scala/DMACommandTracker.scala 89:11]
        end
    `ifdef PRINTF_COND
      end
    `endif
    `endif // SYNTHESIS
    `ifndef SYNTHESIS
    `ifdef STOP_COND
      if (`STOP_COND) begin
    `endif
        if (_GEN_29 & ~(_GEN_15 >= io_request_returned_bits_bytes_read)) begin
          $fatal; // @[src/main/scala/DMACommandTracker.scala 89:11]
        end
    `ifdef STOP_COND
      end
    `endif
    `endif // SYNTHESIS
  end
// Register and memory initialization
`ifdef RANDOMIZE_GARBAGE_ASSIGN
`define RANDOMIZE
`endif
`ifdef RANDOMIZE_INVALID_ASSIGN
`define RANDOMIZE
`endif
`ifdef RANDOMIZE_REG_INIT
`define RANDOMIZE
`endif
`ifdef RANDOMIZE_MEM_INIT
`define RANDOMIZE
`endif
`ifndef RANDOM
`define RANDOM $random
`endif
`ifdef RANDOMIZE_MEM_INIT
  integer initvar;
`endif
`ifndef SYNTHESIS
`ifdef FIRRTL_BEFORE_INITIAL
`FIRRTL_BEFORE_INITIAL
`endif
initial begin
  `ifdef RANDOMIZE
    `ifdef INIT_RANDOM
      `INIT_RANDOM
    `endif
    `ifndef VERILATOR
      `ifdef RANDOMIZE_DELAY
        #`RANDOMIZE_DELAY begin end
      `else
        #0.002 begin end
      `endif
    `endif
`ifdef RANDOMIZE_REG_INIT
  _RAND_0 = {1{`RANDOM}};
  cmds_0_valid = _RAND_0[0:0];
  _RAND_1 = {1{`RANDOM}};
  cmds_0_tag = _RAND_1[3:0];
  _RAND_2 = {1{`RANDOM}};
  cmds_0_bytes_left = _RAND_2[7:0];
  _RAND_3 = {1{`RANDOM}};
  cmds_1_valid = _RAND_3[0:0];
  _RAND_4 = {1{`RANDOM}};
  cmds_1_tag = _RAND_4[3:0];
  _RAND_5 = {1{`RANDOM}};
  cmds_1_bytes_left = _RAND_5[7:0];
`endif // RANDOMIZE_REG_INIT
  `endif // RANDOMIZE
end // initial
`ifdef FIRRTL_AFTER_INITIAL
`FIRRTL_AFTER_INITIAL
`endif
`endif // SYNTHESIS
endmodule
module GatedTracker(
  input        clock,
  input        reset,
  input        io_gate_write, // @[src/main/scala/Emit.scala 14:14]
  input        io_gate_value, // @[src/main/scala/Emit.scala 14:14]
  input        io_alloc, // @[src/main/scala/Emit.scala 14:14]
  input  [7:0] io_bytes, // @[src/main/scala/Emit.scala 14:14]
  input  [3:0] io_tag, // @[src/main/scala/Emit.scala 14:14]
  input        io_returned, // @[src/main/scala/Emit.scala 14:14]
  input        io_returned_id, // @[src/main/scala/Emit.scala 14:14]
  input  [7:0] io_returned_bytes, // @[src/main/scala/Emit.scala 14:14]
  input        io_accept, // @[src/main/scala/Emit.scala 14:14]
  output       io_ready, // @[src/main/scala/Emit.scala 14:14]
  output       io_id, // @[src/main/scala/Emit.scala 14:14]
  output       io_valid, // @[src/main/scala/Emit.scala 14:14]
  output       io_out_id, // @[src/main/scala/Emit.scala 14:14]
  output [3:0] io_out_tag, // @[src/main/scala/Emit.scala 14:14]
  output       io_busy // @[src/main/scala/Emit.scala 14:14]
);
`ifdef RANDOMIZE_REG_INIT
  reg [31:0] _RAND_0;
`endif // RANDOMIZE_REG_INIT
  wire  cg_in; // @[src/main/scala/Emit.scala 32:18]
  wire  cg_en; // @[src/main/scala/Emit.scala 32:18]
  wire  cg_test_en; // @[src/main/scala/Emit.scala 32:18]
  wire  cg_out; // @[src/main/scala/Emit.scala 32:18]
  wire  tracker_clock; // @[src/main/scala/Emit.scala 36:46]
  wire  tracker_reset; // @[src/main/scala/Emit.scala 36:46]
  wire  tracker_io_alloc_valid; // @[src/main/scala/Emit.scala 36:46]
  wire  tracker_io_alloc_ready; // @[src/main/scala/Emit.scala 36:46]
  wire [3:0] tracker_io_alloc_bits_tag; // @[src/main/scala/Emit.scala 36:46]
  wire [7:0] tracker_io_alloc_bits_bytes_to_read; // @[src/main/scala/Emit.scala 36:46]
  wire  tracker_io_alloc_bits_cmd_id; // @[src/main/scala/Emit.scala 36:46]
  wire  tracker_io_request_returned_valid; // @[src/main/scala/Emit.scala 36:46]
  wire [7:0] tracker_io_request_returned_bits_bytes_read; // @[src/main/scala/Emit.scala 36:46]
  wire  tracker_io_request_returned_bits_cmd_id; // @[src/main/scala/Emit.scala 36:46]
  wire  tracker_io_cmd_completed_ready; // @[src/main/scala/Emit.scala 36:46]
  wire  tracker_io_cmd_completed_valid; // @[src/main/scala/Emit.scala 36:46]
  wire  tracker_io_cmd_completed_bits_cmd_id; // @[src/main/scala/Emit.scala 36:46]
  wire [3:0] tracker_io_cmd_completed_bits_tag; // @[src/main/scala/Emit.scala 36:46]
  wire  tracker_io_busy; // @[src/main/scala/Emit.scala 36:46]
  reg  running; // @[src/main/scala/Emit.scala 31:24]
  wire  _GEN_0 = io_gate_write & ~io_busy ? io_gate_value : running; // @[src/main/scala/Emit.scala 31:24 37:{35,45}]
  EICG_wrapper cg ( // @[src/main/scala/Emit.scala 32:18]
    .in(cg_in),
    .en(cg_en),
    .test_en(cg_test_en),
    .out(cg_out)
  );
  DMACommandTracker tracker ( // @[src/main/scala/Emit.scala 36:46]
    .clock(tracker_clock),
    .reset(tracker_reset),
    .io_alloc_valid(tracker_io_alloc_valid),
    .io_alloc_ready(tracker_io_alloc_ready),
    .io_alloc_bits_tag(tracker_io_alloc_bits_tag),
    .io_alloc_bits_bytes_to_read(tracker_io_alloc_bits_bytes_to_read),
    .io_alloc_bits_cmd_id(tracker_io_alloc_bits_cmd_id),
    .io_request_returned_valid(tracker_io_request_returned_valid),
    .io_request_returned_bits_bytes_read(tracker_io_request_returned_bits_bytes_read),
    .io_request_returned_bits_cmd_id(tracker_io_request_returned_bits_cmd_id),
    .io_cmd_completed_ready(tracker_io_cmd_completed_ready),
    .io_cmd_completed_valid(tracker_io_cmd_completed_valid),
    .io_cmd_completed_bits_cmd_id(tracker_io_cmd_completed_bits_cmd_id),
    .io_cmd_completed_bits_tag(tracker_io_cmd_completed_bits_tag),
    .io_busy(tracker_io_busy)
  );
  assign io_ready = running & tracker_io_alloc_ready; // @[src/main/scala/Emit.scala 45:23]
  assign io_id = io_ready & tracker_io_alloc_bits_cmd_id; // @[src/main/scala/Emit.scala 46:15]
  assign io_valid = running & tracker_io_cmd_completed_valid; // @[src/main/scala/Emit.scala 47:23]
  assign io_out_id = io_valid & tracker_io_cmd_completed_bits_cmd_id; // @[src/main/scala/Emit.scala 48:19]
  assign io_out_tag = io_valid ? tracker_io_cmd_completed_bits_tag : 4'h0; // @[src/main/scala/Emit.scala 49:20]
  assign io_busy = io_alloc | running & tracker_io_busy; // @[src/main/scala/Emit.scala 50:23]
  assign cg_in = clock; // @[src/main/scala/Emit.scala 33:12]
  assign cg_en = running; // @[src/main/scala/Emit.scala 34:12]
  assign cg_test_en = 1'h0; // @[src/main/scala/Emit.scala 35:17]
  assign tracker_clock = cg_out;
  assign tracker_reset = reset;
  assign tracker_io_alloc_valid = io_alloc; // @[src/main/scala/Emit.scala 38:26]
  assign tracker_io_alloc_bits_tag = io_tag; // @[src/main/scala/Emit.scala 39:29]
  assign tracker_io_alloc_bits_bytes_to_read = io_bytes; // @[src/main/scala/Emit.scala 40:39]
  assign tracker_io_request_returned_valid = io_returned; // @[src/main/scala/Emit.scala 41:37]
  assign tracker_io_request_returned_bits_bytes_read = io_returned_bytes; // @[src/main/scala/Emit.scala 43:47]
  assign tracker_io_request_returned_bits_cmd_id = io_returned_id; // @[src/main/scala/Emit.scala 42:43]
  assign tracker_io_cmd_completed_ready = io_accept; // @[src/main/scala/Emit.scala 44:34]
  always @(posedge clock) begin
    running <= reset | _GEN_0; // @[src/main/scala/Emit.scala 31:{24,24}]
  end
// Register and memory initialization
`ifdef RANDOMIZE_GARBAGE_ASSIGN
`define RANDOMIZE
`endif
`ifdef RANDOMIZE_INVALID_ASSIGN
`define RANDOMIZE
`endif
`ifdef RANDOMIZE_REG_INIT
`define RANDOMIZE
`endif
`ifdef RANDOMIZE_MEM_INIT
`define RANDOMIZE
`endif
`ifndef RANDOM
`define RANDOM $random
`endif
`ifdef RANDOMIZE_MEM_INIT
  integer initvar;
`endif
`ifndef SYNTHESIS
`ifdef FIRRTL_BEFORE_INITIAL
`FIRRTL_BEFORE_INITIAL
`endif
initial begin
  `ifdef RANDOMIZE
    `ifdef INIT_RANDOM
      `INIT_RANDOM
    `endif
    `ifndef VERILATOR
      `ifdef RANDOMIZE_DELAY
        #`RANDOMIZE_DELAY begin end
      `else
        #0.002 begin end
      `endif
    `endif
`ifdef RANDOMIZE_REG_INIT
  _RAND_0 = {1{`RANDOM}};
  running = _RAND_0[0:0];
`endif // RANDOMIZE_REG_INIT
  `endif // RANDOMIZE
end // initial
`ifdef FIRRTL_AFTER_INITIAL
`FIRRTL_AFTER_INITIAL
`endif
`endif // SYNTHESIS
endmodule
