#!/bin/sh
set -eu
cd /opt/uu-wol-g7615
[ -f managed-v1 ] && [ ! -f uninstalled ] || exit 1
sha256sum -c payload.sha256 >/dev/null || exit 1
# Let the native framework supervise the foreground process and collect logs.
exec ./uuplugin ./uu.conf
