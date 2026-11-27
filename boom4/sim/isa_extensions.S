.option norvc
.text
.globl _start
_start:
  csrr x2, misa
  andi x2, x2, 41
  slli x2, x2, 6
  li x1, 1
  slli x1, x1, 31
  add x1, x1, x2
  ld x3, 0(x1)
done:
  j done
