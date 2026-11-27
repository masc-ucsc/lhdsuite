# The boot ROM in coherent_harts.prp packs two RV64 instructions per beat.
.option norvc
.text
.rept 127
  nop
.endr
j coherence
.rept 128
  jal zero,.
.endr
coherence:
csrr t0,mhartid
andi t1,t0,1
slli t1,t1,6
li t2,1
slli t2,t2,31
add t2,t2,t1
andi t0,t0,2
bnez t0,reader
lui t3,0x10
addi t3,t3,0x200
add t3,t3,t1
sd t3,0(t2)
writer_done:
j writer_done
reader:
ld t3,0(t2)
beqz t3,reader
jr t3
