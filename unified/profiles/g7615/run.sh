#!/bin/sh
set -eu
cd /opt/uu-wol-g7615
[ -f managed-v1 ] && [ ! -f uninstalled ] || exit 1
# SHA256 validation is performed by the host before installation/management.
# The trimmed CU userspace has no sha256sum; procd boot uses installed files.
# Let the native framework supervise the foreground process and collect logs.
exec ./uuplugin ./uu.conf
