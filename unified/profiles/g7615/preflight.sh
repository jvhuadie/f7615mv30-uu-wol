#!/bin/sh
# Read-only: locate the framework root, never an application container.
set -eu
[ "$(id -u)" = 0 ] && [ "$(uname -n)" = G7615V2 ] && [ "$(uname -m)" = aarch64 ] || exit 10
echo '0afb71c8d938a82395675bc1fa96cb10ec23f5a9ab9f4f3d66073257d02c7b36  /bin/cspd' | sha256sum -c - >/dev/null || exit 11
echo '42b63762cec38f78bf1248245061e753d38ecbefdb5945f74356c5bff8262a40  /bin/ufwmg' | sha256sum -c - >/dev/null || exit 11
count=0
for p in /proc/[0-9]*; do
 [ "$(cat "$p/comm" 2>/dev/null)" = procd ] || continue
 [ "$(readlink "$p/ns/net")" = "$(readlink /proc/1/ns/net)" ] || continue
 # Field 4 must be /: nested application roots must never match.
 awk '$4=="/" && $5=="/" && $6 ~ /^rw(,|$)/ && / - overlay / && /lowerdir=\/opt\/cu\/framework\/ufw\/rootfs,upperdir=\/opt\/cu\/apps\/apps,workdir=\/opt\/cu\/apps\/work(,|$)/ {ok=1} END {exit !ok}' "$p/mountinfo" || continue
 count=$((count+1)); root="$p/root"
done
[ "$count" = 1 ] || { echo FRAMEWORK_ROOT_NOT_UNIQUE >&2; exit 12; }
for d in opt etc etc/init.d etc/rc.d; do
 [ -d "$root/$d" ] && [ ! -L "$root/$d" ] || exit 13
done
for f in bin/sh etc/rc.common lib/functions.sh lib/functions/procd.sh usr/share/libubox/jshn.sh; do
 [ -r "$root/$f" ] || { echo "FRAMEWORK_MISSING:$f" >&2; exit 14; }
done
[ -x /usr/sbin/chroot ] || exit 14
# Verify real framework APIs and bus availability, without registering a service.
/usr/sbin/chroot "$root" /bin/sh -c 'missing=; for tool in readlink cmp cp chmod rm mkdir rmdir sleep; do type "$tool" >/dev/null 2>&1 || missing="$missing $tool"; done; [ -z "$missing" ] || { echo "FRAMEWORK_TOOLS_MISSING:$missing" >&2; exit 1; }; . /lib/functions.sh; . /lib/functions/procd.sh; type procd_open_instance >/dev/null && type procd_set_param >/dev/null && type procd_close_instance >/dev/null && ubus list service | grep -qx service && test -d /sys/class/net/br0 && test -r /proc/1/stat && test / -ef /' || exit 15
echo "$root"
