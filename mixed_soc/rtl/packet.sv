// Connectivity fixture: transport the TileLink fields used by the vendored tiles.
package mixed_packet;
  typedef enum logic [2:0] {A, B, C, D, E} channel_t;
  typedef struct packed {
    logic [4:0] origin, target;
    channel_t ch;
    logic [3:0] opcode, size;
    logic [2:0] param, tl_source, sink;
    logic [31:0] addr;
    logic [7:0] mask;
    logic [63:0] data;
    logic corrupt, denied;
  } packet_t;
  localparam logic [31:0] ACC_BASE = 32'h0001_8000;
  // The window: 64 accumulator rows of 64 bytes (0x0000..0x0fff), then the mesh registers (0x1000..0x10ff, see acc.sv).
  localparam logic [31:0] ACC_SIZE = 32'h0000_2000;
  function automatic bit acc_address(input logic [31:0] addr);
    return addr >= ACC_BASE && addr < ACC_BASE + ACC_SIZE;
  endfunction
endpackage
