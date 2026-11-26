import chisel3._
import chisel3.stage.ChiselStage
class EICG_wrapper extends BlackBox {
  val io = IO(new Bundle {
    val in = Input(Clock())
    val en = Input(Bool())
    val test_en = Input(Bool())
    val out = Output(Clock())
  })
}
// The load-controller tracker below runs on the same gated clock as its
// parent in gemmini/Controller.scala. A software gate write requires !busy.
class GatedTracker extends Module {
  val io = IO(new Bundle {
    val gate_write = Input(Bool())
    val gate_value = Input(Bool())
    val alloc = Input(Bool())
    val bytes = Input(UInt(8.W))
    val tag = Input(UInt(4.W))
    val returned = Input(Bool())
    val returned_id = Input(UInt(1.W))
    val returned_bytes = Input(UInt(8.W))
    val accept = Input(Bool())
    val ready = Output(Bool())
    val id = Output(UInt(1.W))
    val valid = Output(Bool())
    val out_id = Output(UInt(1.W))
    val out_tag = Output(UInt(4.W))
    val busy = Output(Bool())
  })
  val running = RegInit(true.B)
  val cg = Module(new EICG_wrapper)
  cg.io.in := clock
  cg.io.en := running
  cg.io.test_en := false.B
  val tracker = withClock(cg.io.out) { Module(new gemmini.DMACommandTracker(2, 255, UInt(4.W))) }
  when(io.gate_write && !io.busy) { running := io.gate_value }
  tracker.io.alloc.valid := io.alloc
  tracker.io.alloc.bits.tag := io.tag
  tracker.io.alloc.bits.bytes_to_read := io.bytes
  tracker.io.request_returned.valid := io.returned
  tracker.io.request_returned.bits.cmd_id := io.returned_id
  tracker.io.request_returned.bits.bytes_read := io.returned_bytes
  tracker.io.cmd_completed.ready := io.accept
  io.ready := running && tracker.io.alloc.ready
  io.id := Mux(io.ready, tracker.io.alloc.bits.cmd_id, 0.U)
  io.valid := running && tracker.io.cmd_completed.valid
  io.out_id := Mux(io.valid, tracker.io.cmd_completed.bits.cmd_id, 0.U)
  io.out_tag := Mux(io.valid, tracker.io.cmd_completed.bits.tag, 0.U)
  io.busy := io.alloc || (running && tracker.io.busy)
}
object Emit extends App {
  (new ChiselStage).emitVerilog(new GatedTracker, Array("--target-dir", "rtl"))
}
