# The test sets mhartid to the high virtual-address bit used by the program.
.option norvc
.global _start
_start:
  li t0,-1
  csrw pmpaddr0,t0
  li t0,15
  csrw pmpcfg0,t0
  csrr t1,mhartid
  li t0,1
  slli t0,t0,11
  csrw mstatus,t0
  li t0,1
  sll t0,t0,t1
  csrw mepc,t0
  li t2,42
  li t0,9
  beq t1,t2,1f
  li t0,10
1:slli t0,t0,60
  li t1,0x80010
  or t0,t0,t1
  csrw satp,t0
  sfence.vma
  mret

.section .supervisor,"ax"
  auipc t0,0
  ld tp,128(t0)
  addi t1,tp,1
1:j 1b
