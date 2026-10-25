sub sp, sp, #256
mov x8, #174
svc #0
cbnz x0, denied
mov x0, #-100
adr x1, path
mov x2, #0x8000
movk x2, #8, lsl #16
mov x3, #0
mov x8, #56
svc #0
tbnz x0, #63, failed
mov x19, x0
mov x1, sp
mov x8, #80
svc #0
tbnz x0, #63, failed
ldr w0, [sp, #16]
and w0, w0, #0xf000
mov w1, #0x8000
cmp w0, w1
b.ne denied
ldr w0, [sp, #20]
cmp w0, #1
b.ne denied
ldr w0, [sp, #24]
cbnz w0, denied
mov x0, x19
mov x1, #0x6601
movk x1, #0x8008, lsl #16
mov x2, sp
mov x8, #29
svc #0
tbnz x0, #63, failed
ldr w3, [sp]
and w3, w3, #0xffffffef
str w3, [sp]
mov x0, x19
mov x1, #0x6602
movk x1, #0x4008, lsl #16
mov x2, sp
mov x8, #29
svc #0
tbnz x0, #63, failed
mov x0, #1
mov x1, sp
mov x2, #4
mov x8, #64
svc #0
mov x0, #0
b done
failed:
neg x0, x0
b done
denied:
mov x0, #77
done:
mov x8, #93
svc #0
path:
.byte 95,95,70,55,48,48,53,95,84,65,82,71,69,84,95,80,65,84,72,95,95,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
