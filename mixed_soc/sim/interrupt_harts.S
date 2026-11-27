# Same RV32I instructions on Rocket 3 and RV64 BOOMs 12 and 13.
.option norvc
.text
.globl _start
_start:
  j start
.org 0x40
  j start
start:
  csrr s0, mhartid
  la t0, trap
  csrw mtvec, t0
  li s1, 0
  li s2, 0x02000000
  slli t0, s0, 2
  add s3, s2, t0                   # this hart's MSIP
  li s7, 1
  slli s7, s7, 31                   # physical 0x80000000 on both RV32 and RV64
  li s8, 0x112233
  li s9, 0x445566
  li t0, 3
  bne s0, t0, boom
  sw s8, 4(s7)
  sw s9, 60(s7)                     # two different 32-bit lanes on the dirty line
  fence rw, ow
  li t0, 1
  sw t0, 48(s2)                     # hand ownership to BOOM 12
  li s4, 1
  li t0, 8
  j arm
boom:
  addi s5, s0, -11                  # interrupt source ID 1 or 2
  li t0, 0x0c000000
  slli t1, s5, 2
  add t1, t1, t0
  sw s5, 0(t1)                      # source priority
  addi t1, s0, -12
  slli t1, t1, 1
  addi t1, t1, 12                   # M contexts 12 and 14
  slli t2, t1, 7
  li t3, 0x0c002000
  add t2, t2, t3
  li t3, 1
  sll t3, t3, s5
  sw t3, 0(t2)
  slli t1, t1, 12
  li s6, 0x0c200004
  add s6, s6, t1                    # context's claim/complete register
  li t0, 0x02004000
  slli t1, s0, 3
  add t0, t0, t1
  sw zero, 4(t0)
  li t1, 2000
  add t1, t1, s0
  sw t1, 0(t0)
  li s4, 7
  li t0, 0x888
arm:
  csrw mie, t0
  csrsi mstatus, 8
wait:
  bne s1, s4, wait
  fence ir, rw
  li t0, 3
  beq s0, t0, rocket_check
  addi t0, s0, -12                  # BOOM 12 expects seed, BOOM 13 expects seed+1
  j check
rocket_check:
  li t0, 2                          # Rocket must see BOOM 13's changes
check:
  add s8, s8, t0
  add s9, s9, t0
  lw t1, 4(s7)
  bne t1, s8, failed
  lw t1, 60(s7)
  bne t1, s9, failed
  li t0, 3
  beq s0, t0, certify
  addi s8, s8, 1
  addi s9, s9, 1
  sw s8, 4(s7)
  sw s9, 60(s7)
  fence rw, ow
  li t0, 1
  addi t1, s0, -12
  slli t1, t1, 2
  add t1, s2, t1
  sw t0, 0(t1)                      # completion flags on parked harts 0 and 1
  fence ow, ow
  li t1, 12
  bne s0, t1, notify_rocket
  sw t0, 52(s2)                     # BOOM 12 hands ownership to BOOM 13
  j done
notify_rocket:
  sw t0, 12(s2)                     # BOOM 13 hands ownership back to Rocket
  j done
certify:
  lw t0, 0(s2)
  lw t1, 4(s2)
  and t0, t0, t1
  beqz t0, failed                   # both BOOMs committed their completion stores
  lui t1, 0x60000
  slli t0, s0, 2
  add t1, t1, t0
  sw s9, 0(t1)                      # externally visible completion after data checks
done:
  slli t0, s0, 7
  lui t1, 0x11
  add t0, t0, t1
  jr t0
.balign 4
trap:
  csrr t0, mcause
  bgez t0, failed
  andi t0, t0, 63
  li t1, 3
  beq t0, t1, software
  li t1, 7
  beq t0, t1, timer
  li t1, 11
  bne t0, t1, failed
  lw t1, 0(s6)
  bne t1, s5, failed
  sw t1, 0(s6)
  li t0, 0x800
  ori s1, s1, 4
  j handled
software:
  sw zero, 0(s3)
  li t0, 8
  ori s1, s1, 1
  j handled
timer:
  li t0, 128
  ori s1, s1, 2
handled:
  csrc mie, t0
  mret
failed:
  j failed
