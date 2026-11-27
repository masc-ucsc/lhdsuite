.option norvc
.text
.globl _start
_start:
  auipc t0, 0
  addi t0, t0, 48
  csrw mtvec, t0
  li a0, 15
  csrw pmpaddr15, a0
  csrr a0, pmpaddr15
select_line:
  li a1, 1
  slli a1, a1, 31
  slli a0, a0, 6
  add a1, a1, a0
  ld a2, 0(a1)
done:
  j done
no_pmp:
  li a0, 3
  j select_line
