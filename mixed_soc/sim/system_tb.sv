// No hierarchical probes: the verdict uses only the four ports at the block boundary.
module mixed_system_tb;
  import mixed_packet::*;
  import mixed_layout::*;
  bit clock=0, reset=1; always #1 clock=~clock;
  logic [15:0] core_enable='1;
  logic host_req_valid, host_req_ready, host_rsp_valid, host_rsp_ready;
  logic mem_req_valid, mem_req_ready, mem_rsp_valid, mem_rsp_ready;
  packet_t host_req,host_rsp,mem_req,mem_rsp;
  mixed_soc dut(.*);

  function automatic int entry(int id); return BOOMS[id] ? 'h10000 : 'h10040; endfunction
  function automatic int landing(int id); return 'h10200+128*id; endfunction
  function automatic int finish_pc(int id); return 'h11000+128*(15-id); endfunction
  function automatic logic [31:0] instruction(int addr, int id);
    int imm, ptr;
    imm=landing(id)-entry(id);
    ptr=ACC_BASE+2048*((id/2)%3)+'h100+4*id;
    if(addr==entry(id)) return {imm[20],imm[10:1],imm[11],imm[19:12],5'b0,7'h6f}; // jal x0, landing
    if(addr==landing(id)) return ((32'(ptr)+32'h800) & 32'hfffff000) | 32'h000000b7; // lui x1, ACC_BASE[31:12]
    if(addr==landing(id)+4) return (32'(ptr & 'hfff)<<20) | 32'h0000a103; // lw x2, offset(x1)
    if(addr==landing(id)+8) return 32'h00010067; // jalr x0, 0(x2): use the actual accumulator word
    if(addr==finish_pc(id)) return 32'h0000006f; // jal x0, 0
    return 32'h00000013; // nop
  endfunction
  integer cycles=0, beat=0, beats=0;
  packet_t saved;
  bit [15:0] boot_seen, landed, finished;
  bit vectors_ready=0;
  // Accept boot fetches while the external initiator preloads Gemmini over the
  // same mesh. Each memory response still targets the original requester.
  packet_t queue[32];
  int pushed=0, popped=0;
  bit mmio_done=0;
  assign mem_req_ready=pushed-popped<32 && cycles%7!=2;
  assign mem_rsp_valid=beats!=0;
  always_comb begin
    int id, addr, width_bytes;
    id=int'(saved.origin);
    width_bytes=(id<N && BOOMS[id]) ? 8 : 4;
    addr=(int'(saved.addr) & -width_bytes)+width_bytes*beat;
    mem_rsp='0; mem_rsp.ch=D; mem_rsp.target=saved.origin; mem_rsp.tl_source=saved.tl_source;
    mem_rsp.size=saved.size; mem_rsp.opcode=saved.opcode==6 ? 5 : 1;
    mem_rsp.data={instruction(addr+4,id),instruction(addr,id)};
  end
  always @(posedge clock) if(!reset) begin
    cycles<=cycles+1;
    if(mem_req_valid && mem_req_ready) begin
      int id;
      id=int'(mem_req.origin);
      if(id>=16 || mem_req.target!=5'(HOST) || mem_req.ch!=A || !(mem_req.opcode inside {4,6}))
        $fatal(1,"unexpected CPU memory transaction from %0d ch=%0d op=%0d",id,mem_req.ch,mem_req.opcode);
      if(acc_address(mem_req.addr)) $fatal(1,"CPU accumulator access escaped to external memory");
      if(mem_req.corrupt || mem_req.size>6) $fatal(1,"invalid fetch");
      queue[pushed%32]<=mem_req; pushed<=pushed+1;
      if((mem_req.addr>>6)==(entry(id)>>6)) boot_seen[id]<=1;
      if(mem_req.addr>=32'h10200 && mem_req.addr<32'h10a00) begin
        if((mem_req.addr>>6)!=(landing(id)>>6)) $fatal(1,"CPU %0d fetched another tile's boot destination: %h",id,mem_req.addr);
        if(!boot_seen[id]) $fatal(1,"missing reset fetch for %0d",id);
        landed[id]<=1;
      end
    end
    // The CPU can only fetch here after consuming its own pointer from Gemmini.
    if(mem_req_valid && mem_req_ready && mem_req.addr>=32'h11000 && mem_req.addr<32'h11800) begin
      int id; id=int'(mem_req.origin);
      if(!landed[id] || (mem_req.addr>>6)!=(finish_pc(id)>>6)) $fatal(1,"bad accumulator branch CPU %0d addr %h",id,mem_req.addr);
      finished[id]<=1;
    end
    if(vectors_ready && beats==0 && pushed!=popped) begin
      packet_t req; int bw; req=queue[popped%32]; bw=BOOMS[req.origin] ? 8 : 4;
      saved<=req; beat<=0; popped<=popped+1;
      beats<=((1<<req.size)>bw) ? (1<<req.size)/bw : 1;
    end
    if(mem_rsp_valid && mem_rsp_ready) begin beats<=beats-1; beat<=beat+1; end
    if(mmio_done && (&finished)) begin
      $display("PASS: 12 Rocket + 4 BOOM booted and branched via 16 pointers read from Gemmini; external MMIO passed (%0d cycles)", cycles);
      $finish;
    end
    if(cycles>=40000) $fatal(1,"timeout: boot=%h landed=%h finished=%h mmio=%0d",boot_seen,landed,finished,mmio_done);
  end

  task automatic mmio(input int op, addr, input logic [63:0] data, expected, input byte mask, input bit denied);
    packet_t held;
    @(negedge clock);
    host_req='0; host_req.target=5'(ACC); host_req.ch=A; host_req.opcode=4'(op); host_req.size=3;
    host_req.addr=addr; host_req.data=data; host_req.mask=mask; host_req.tl_source=addr[5:3]; host_req_valid=1;
    do @(posedge clock); while(!host_req_ready);
    @(negedge clock); host_req_valid=0;
    do @(posedge clock); while(!host_rsp_valid);
    held=host_rsp;
    repeat(3) begin
      @(posedge clock);
      if(!host_rsp_valid || host_rsp!==held) $fatal(1,"host response changed while stalled");
    end
    if(held.origin!=5'(acc_address(addr) ? ACC+((addr-ACC_BASE)>>11) : ACC) || held.target!=5'(HOST) || held.ch!=D || held.tl_source!=host_req.tl_source ||
       held.size!=3 || held.denied!=denied || held.corrupt || held.opcode!=(op==4 ? 1 : 0) ||
       (op==4 && !denied && held.data!==expected)) $fatal(1,"bad MMIO at %h got %h expected %h flags=%b",addr,held.data,expected,held.denied);
    @(negedge clock); host_rsp_ready=1;
    @(posedge clock); @(negedge clock); host_rsp_ready=0;
  endtask
  initial begin
    host_req='0; host_req_valid=0; host_rsp_ready=0;
    repeat(8) @(negedge clock); reset=0;
    for(int i=0;i<16;i+=2)
      mmio(0,ACC_BASE+2048*((i/2)%3)+'h100+4*i,{finish_pc(i+1),finish_pc(i)},0,8'hff,0);
    vectors_ready=1;
    // Distinct words across all four lanes and two rows. Read after all writes to catch aliases.
    for(int i=0;i<8;i++) mmio(0, ACC_BASE+8*i, 64'hd0c0_b0a0_7654_3210 ^ (64'h0101_0101_0101_0101*i),0,8'hff,0);
    for(int i=7;i>=0;i--) mmio(4, ACC_BASE+8*i, 0, 64'hd0c0_b0a0_7654_3210 ^ (64'h0101_0101_0101_0101*i),8'hff,0);
    mmio(1,ACC_BASE,64'hffee_ddcc_bbaa_9988,0,8'h05,0);
    mmio(4,ACC_BASE,0,64'hd0c0_b0a0_76aa_3288,8'hff,0);
    mmio(4,ACC_BASE+3*2048,0,0,8'hff,1); // outside the accumulator window
    mmio_done=1;
  end
endmodule
