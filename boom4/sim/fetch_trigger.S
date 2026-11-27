.option norvc
.text
.globl _start
_start:
  auipc t0, 0
  addi t1, t0, 52
  csrw mtvec, t1
  li a0, 1
  slli a0, a0, 31
  li t2, 1
  csrw tselect, t2
  addi t1, t0, 44
  csrw tdata2, t1
  li t2, 0x44  # match execution in machine mode
  csrw tdata1, t2
watch:
  ld a1, 0(a0)
done:
  j done
trap:
  ld a1, 192(a0)
  j done
