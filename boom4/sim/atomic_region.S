.option norvc
.text
.globl _start
_start:
  auipc t0, 0
  addi t0, t0, 32
  csrw mtvec, t0
  li a0, 1
  slli a0, a0, 31
  csrci misa, 1
  lr.d a1, (a0)
done:
  j done
trap:
  ld a1, 64(a0)
  j done
