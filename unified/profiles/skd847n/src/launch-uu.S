// Fixed-purpose launcher. Accept only Java UID 107; no command/path arguments.
// Open and validate a root-owned target before permanently dropping root.
sub sp, sp, #512
mov x8, #174
svc #0
cmp x0, #107
b.ne denied
mov x8, #175
svc #0
cbnz x0, denied
mov x0, #-100
adr x1, project
mov x2, #0xc000
movk x2, #8, lsl #16
mov x3, #0
mov x8, #56
svc #0
tbnz x0, #63, failed
mov x19, x0
add x1, sp, #64
mov x8, #80
svc #0
cbnz x0, failed
ldr w0, [sp, #88]
cbnz w0, denied
ldr w0, [sp, #80]
mov w1, #0x41ed
cmp w0, w1
b.ne denied
mov x0, x19
adr x1, executable
mov x2, #0x8000
movk x2, #8, lsl #16
mov x3, #0
mov x8, #56
svc #0
tbnz x0, #63, failed
mov x22, x0
add x1, sp, #64
mov x8, #80
svc #0
cbnz x0, failed
ldr w0, [sp, #88]
cbnz w0, denied
ldr w0, [sp, #80]
mov w1, #0x816d
cmp w0, w1
b.ne denied
ldr w0, [sp, #84]
cmp w0, #1
b.ne denied
mov x0, x19
mov x8, #57
svc #0
// The only privileged filesystem operation: create our fixed PID file.
mov x0, #-100
adr x1, runpath
mov x2, #0xc000
movk x2, #8, lsl #16
mov x3, #0
mov x8, #56
svc #0
tbnz x0, #63, failed
mov x19, x0
add x1, sp, #64
mov x8, #80
svc #0
cbnz x0, failed
ldr w0, [sp, #88]
cbnz w0, denied
// /var/run is factory mode 0777. Use pinned dirfd + exclusive/no-follow
// create; chown only the freshly opened inode, never an existing file.
mov x0, x19
adr x1, pidname
mov x2, #0x80c1
movk x2, #8, lsl #16
mov x3, #0x180
mov x8, #56
svc #0
cmn x0, #17
b.eq existing
tbnz x0, #63, failed
mov x20, x0
mov x1, #107
mov x2, #110
mov x8, #55
svc #0
cbnz x0, failed
mov x0, x20
add x1, sp, #64
mov x8, #80
svc #0
cbnz x0, failed
mov x0, x20
mov x8, #57
svc #0
b validate_pid
existing:
mov x0, x19
adr x1, pidname
add x2, sp, #64
mov x3, #0x100
mov x8, #79
svc #0
cbnz x0, failed
validate_pid:
ldr w0, [sp, #80]
mov w1, #0x8180
cmp w0, w1
b.ne denied
ldr w0, [sp, #84]
cmp w0, #1
b.ne denied
ldr w0, [sp, #88]
cmp w0, #107
b.ne denied
ldr w0, [sp, #92]
cmp w0, #110
b.ne denied
mov x0, x19
mov x8, #57
svc #0
// Retain only raw networking after setting all UIDs/GIDs to Java's identity.
mov x0, #8
mov x1, #1
mov x2, #0
mov x3, #0
mov x4, #0
mov x8, #167
svc #0
cbnz x0, failed
mov x0, #0
mov x1, #0
mov x8, #159
svc #0
cbnz x0, failed
mov x0, #110
mov x1, #110
mov x2, #110
mov x8, #149
svc #0
cbnz x0, failed
mov x0, #107
mov x1, #107
mov x2, #107
mov x8, #147
svc #0
cbnz x0, failed
mov w0, #0x0522
movk w0, #0x2008, lsl #16
str w0, [sp]
str wzr, [sp, #4]
mov w0, #0x2000
str w0, [sp, #8]
str w0, [sp, #12]
str w0, [sp, #16]
str wzr, [sp, #20]
str wzr, [sp, #24]
str wzr, [sp, #28]
mov x0, sp
add x1, sp, #8
mov x8, #91
svc #0
cbnz x0, failed
mov x0, #47
mov x1, #2
mov x2, #13
mov x3, #0
mov x4, #0
mov x8, #167
svc #0
cbnz x0, failed
mov x8, #175
svc #0
cmp x0, #107
b.ne denied
adr x0, argvzero
str x0, [sp, #256]
adr x0, config
str x0, [sp, #264]
str xzr, [sp, #272]
adr x0, envpath
str x0, [sp, #288]
str xzr, [sp, #296]
mov x0, x22
adr x1, empty
add x2, sp, #256
add x3, sp, #288
mov x4, #0x1000
mov x8, #281
svc #0
failed:
neg x0, x0
b finish
denied:
mov x0, #77
finish:
mov x8, #93
svc #0
project:
.ascii "/usr/data/uu-wol-skd847n\0"
executable:
.ascii "uuplugin\0"
runpath:
.ascii "/var/run\0"
pidname:
.ascii "uuplugin.pid\0"
argvzero:
.ascii "uuplugin\0"
config:
.ascii "./uu.conf\0"
envpath:
.ascii "PATH=/bin:/sbin:/usr/bin:/usr/sbin\0"
empty:
.ascii "\0"
