.option norvc
.text
.globl _start
_start:
  li x1, 1
  slli x1, x1, 31
  li x2, 64
repeat:
  ld x3, 0(x1)
  ld x4, 16(x1)
  ld x5, 32(x1)
  ld x6, 48(x1)
  addi x2, x2, -1
  bnez x2, repeat
  add x10, x3, x4
  add x10, x10, x5
  add x10, x10, x6
  slli x10, x10, 6
  add x10, x10, x1
  ld x11, 0(x10)
done:
  j done
