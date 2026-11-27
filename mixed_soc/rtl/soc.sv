module mixed_soc import mixed_packet::*; import mixed_layout::*; (
  input logic clock, reset,
  input logic [15:0] core_enable,
  // The external port can both issue MMIO and serve memory for the CPUs.
  input logic host_req_valid, output logic host_req_ready, input packet_t host_req,
  output logic host_rsp_valid, input logic host_rsp_ready, output packet_t host_rsp,
  output logic mem_req_valid, input logic mem_req_ready, output packet_t mem_req,
  input logic mem_rsp_valid, output logic mem_rsp_ready, input packet_t mem_rsp);
  logic [N-1:0] qv, qr, qov, qor, sv, sr, sov, sor;
  packet_t q[N], qo[N], s[N], so[N];
  mixed_mesh requests(.clock,.reset,.txv(qv),.txr(qr),.tx(q),.rxv(qov),.rxr(qor),.rx(qo));
  mixed_mesh responses(.clock,.reset,.txv(sv),.txr(sr),.tx(s),.rxv(sov),.rxr(sor),.rx(so));
  for(genvar i=0;i<N;i++) begin: tile
    if(i==HOST) begin
      // The host initiator addresses the Gemmini window; bad accesses
      // get a denied response. CPU reply destinations are explicitly tagged.
      always_comb begin q[i]=host_req; q[i].target=5'(ACC); end
      assign qv[i]=host_req_valid; assign host_req_ready=qr[i];
      assign host_rsp_valid=sov[i]; assign host_rsp=so[i]; assign sor[i]=host_rsp_ready;
      assign mem_req_valid=qov[i]; assign mem_req=qo[i]; assign qor[i]=mem_req_ready;
      wire cpu_dest=mem_rsp.target<5'(N) && !(mem_rsp.target>=5'(ACC) && mem_rsp.target<5'(ACC+ACC_COUNT)) && mem_rsp.target!=5'(HOST);
      wire allowed=cpu_dest && (mem_rsp.ch==D || mem_rsp.ch==B);
      assign sv[i]=mem_rsp_valid && allowed; assign s[i]=mem_rsp; assign mem_rsp_ready=sr[i] && allowed;
    end else if(i>=ACC && i<ACC+ACC_COUNT) begin
      mixed_acc accelerator(.clock,.reset,.rxv(qov[i]),.rxr(qor[i]),.rx(qo[i]),.txv(sv[i]),.txr(sr[i]),.tx(s[i]));
      assign qv[i]=0; assign q[i]='0; assign sor[i]=0;
    end else begin
      mixed_cpu #(.IS_BOOM(BOOMS[i]),.ID(i),.HOST(HOST),.ACC(ACC)) cpu(.clock,.reset(reset || !core_enable[i]),.txv(qv[i]),.txr(qr[i]),
        .tx(q[i]),.rxv(sov[i]),.rxr(sor[i]),.rx(so[i]));
      assign sv[i]=0; assign s[i]='0; assign qor[i]=0;
    end
  end
endmodule
