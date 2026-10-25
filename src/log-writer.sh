#!/bin/sh
# Bounded pipe consumer: at most 256 KiB per file, one previous file.
# dd count limits input records, including short records; chunks can be smaller.
# Never apply a file-size signal limit to the UU process.
set -u
umask 077
LOG=${1:-/tmp/uu-f7615-service.log}
PIDFILE=${2:-/tmp/uu-f7615-log-writer.pid}
PREVIOUS=$LOG.previous
drain() { cat >/dev/null; }
for path in "$LOG" "$PREVIOUS" "$PIDFILE"; do
    if [ -L "$path" ] || { [ -e "$path" ] && [ ! -f "$path" ]; }; then
        drain
        exit 1
    fi
done
echo $$ > "$PIDFILE" || { drain; exit 1; }
trap 'rm -f "$PIDFILE"' 0
# Bound any pre-v0.3 log before accepting new data. Old output is disposable.
if [ -s "$LOG" ]; then
    dd if="$LOG" of="$PREVIOUS" bs=1024 count=256 2>/dev/null || {
        rm -f "$LOG" "$PREVIOUS"
        drain
        exit 1
    }
elif [ -e "$PREVIOUS" ]; then
    # Retain a bounded previous-only file across a normal stop/start.
    bytes=$(wc -c < "$PREVIOUS")
    if [ "$bytes" -gt 262144 ]; then
        rm -f "$PREVIOUS" || { drain; exit 1; }
    fi
fi
# An external command keeps an open failure recoverable in old ash; a failed
# redirection on the special builtin ":" can terminate the shell immediately.
dd if=/dev/null of="$LOG" count=0 2>/dev/null || { drain; exit 1; }
chmod 600 "$LOG" || { drain; exit 1; }
[ ! -f "$PREVIOUS" ] || chmod 600 "$PREVIOUS"
while :; do
    # Directly consume a fixed number of bounded reads from the pipe.
    # On disk/full/write errors, continue draining so UU does not get SIGPIPE.
    if ! dd of="$LOG" bs=1024 count=256 2>/dev/null; then
        drain
        exit 1
    fi
    [ -s "$LOG" ] || break
    chmod 600 "$LOG" || { drain; exit 1; }
    mv -f "$LOG" "$PREVIOUS" || { drain; exit 1; }
done
exit 0
