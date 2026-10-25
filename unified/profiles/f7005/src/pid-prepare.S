// Only creates or validates /var/run/uuplugin.pid. No arguments, shell or network.
// Requires real/effective UID 58327. Only CAP_DAC_OVERRIDE is installed on this file.
sub sp, sp, #256
mov x8, #174
svc #0
mov x1, #58327
cmp x0, x1
b.ne denied
mov x8, #175
svc #0
mov x1, #58327
cmp x0, x1
b.ne denied
mov x0, #-100
adr x1, parent
// arm64 overrides O_DIRECTORY=0x4000 and O_NOFOLLOW=0x8000.
mov x2, #0xc000
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
ldr w0, [sp, #24]
cbnz w0, denied
ldr w0, [sp, #16]
and w1, w0, #0xf000
mov w2, #0x4000
cmp w1, w2
b.ne denied
mov w1, #0x12
tst w0, w1
b.ne denied
mov x0, x19
adr x1, filename
mov x2, #0x80c1
movk x2, #8, lsl #16
mov x3, #0x180
mov x8, #56
svc #0
cmn x0, #17
b.eq existing
tbnz x0, #63, failed
mov x20, x0
mov x1, sp
mov x8, #80
svc #0
mov x21, x0
mov x0, x20
mov x8, #57
svc #0
mov x0, x21
tbnz x0, #63, failed
b validate
existing:
mov x0, x19
adr x1, filename
mov x2, sp
mov x3, #0x100
mov x8, #79
svc #0
tbnz x0, #63, failed
validate:
ldr w0, [sp, #16]
mov w1, #0x8180
cmp w0, w1
b.ne denied
ldr w0, [sp, #20]
cmp w0, #1
b.ne denied
ldr w0, [sp, #24]
mov w1, #58327
cmp w0, w1
b.ne denied
ldr w0, [sp, #28]
cbnz w0, denied
mov x0, x19
mov x8, #57
svc #0
mov x0, #1
add x1, sp, #8
mov x2, #8
mov x8, #64
svc #0
mov x0, #0
b exit
failed:
neg x0, x0
b exit
denied:
mov x0, #77
exit:
mov x8, #93
svc #0
parent:
.ascii "/var/run\0"
filename:
.ascii "uuplugin.pid\0"
