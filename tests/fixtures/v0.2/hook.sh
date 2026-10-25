#!/bin/sh
# UU_F7615_AUTOSTART_V2
ROOT=/usr/plugin/uu-wol-f7615
[ -f "$ROOT/enabled" ] || exit 0
[ ! -f "$ROOT/uninstalled" ] || exit 0
(
    trap '' HUP
    sleep 20
    [ -f "$ROOT/enabled" ] && [ ! -f "$ROOT/uninstalled" ] || exit 0
    sh "$ROOT/control.sh" start
) </dev/null >/tmp/uu-f7615-boot.log 2>&1 &
exit 0
