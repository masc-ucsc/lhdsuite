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
  function automatic bit acc_address(input logic [31:0] addr);
    return addr >= ACC_BASE && addr < ACC_BASE + 3*2048;
  endfunction
endpackage
