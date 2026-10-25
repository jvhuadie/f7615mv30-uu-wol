#!/bin/sh
set -u
PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH
umask 077
ROOT=/usr/plugin/uu-wol-f7615
FILES=$ROOT/files
LOG=/tmp/uu-f7615-service.log
HOOK=/wlan/wifi_debug.sh
LOCK=/tmp/uu-f7615-start.lock
owned_pids() {
    for entry in /proc/[0-9]*; do
        cwd=$(readlink "$entry/cwd" 2>/dev/null) || continue
        [ "$cwd" = "$1" ] || continue
        exe=$(readlink "$entry/exe" 2>/dev/null) || continue
        case "$exe" in "$1/uuplugin"|"$1/xuplugin-guardian")
            [ -z "${2:-}" ] || [ "${exe##*/}" = "$2" ] || continue
            echo "${entry##*/}" ;;
        esac
    done
}
stop_dir() {
    pids=$(owned_pids "$1")
    [ -n "$pids" ] || return 0
    for pid in $pids; do kill -STOP "$pid" 2>/dev/null || :; done
    for pid in $pids; do kill -TERM "$pid" 2>/dev/null || :; done
    for pid in $pids; do kill -CONT "$pid" 2>/dev/null || :; done
    sleep 3
    [ -z "$(owned_pids "$1")" ] || { echo 'STOP_INCOMPLETE; no PID file was removed.' >&2; return 1; }
}
start_service() {
    [ -f "$ROOT/.uu-f7615-managed-v2" ] || { echo 'Managed installation missing'; return 1; }
    [ ! -f "$ROOT/uninstalled" ] || { echo 'Installation was uninstalled; recovery review required.'; return 1; }
    if ! mkdir "$LOCK" 2>/dev/null; then
        owner=$(cat "$LOCK/pid" 2>/dev/null || echo '')
        case "$owner" in ''|*[!0-9]*) echo 'START_LOCK_BUSY'; return 1 ;; esac
        if kill -0 "$owner" 2>/dev/null; then echo 'START_ALREADY_IN_PROGRESS'; return 0; fi
        rm -f "$LOCK/pid"
        rmdir "$LOCK" || return 1
        mkdir "$LOCK" || return 1
    fi
    echo $$ > "$LOCK/pid"
    trap 'rm -f /tmp/uu-f7615-start.lock/pid; rmdir /tmp/uu-f7615-start.lock 2>/dev/null || :' 0
    if [ -n "$(owned_pids "$FILES" uuplugin)" ]; then echo 'ALREADY_RUNNING'; return 0; fi
    stop_dir "$FILES" || return 1
    if ps | grep '[u]uplugin .*uu.conf' >/dev/null; then
        echo 'FOREIGN_UU_RUNNING: refusing a duplicate instance.' >&2
        return 1
    fi
    # Vendor initialization changes /usr/plugin ownership on every boot.
    chown -R root:root "$ROOT" || return 1
    chmod 700 "$ROOT" "$FILES" || return 1
    [ ! -s "$LOG" ] || mv -f "$LOG" "$LOG.previous"
    sh -c 'trap "" HUP; cd /usr/plugin/uu-wol-f7615/files || exit 1; exec ./uuplugin ./uu.conf' </dev/null >"$LOG" 2>&1 &
    sleep 5
    if [ -z "$(owned_pids "$FILES" uuplugin)" ]; then
        echo 'START_FAILED'; sed -n '1,100p' "$LOG"; return 1
    fi
    echo 'PROCESS_STARTED; cloud and remote-wake validation are still required.'
}
status_service() {
    if [ -f "$ROOT/enabled" ] && cmp -s "$ROOT/hook.sh" "$HOOK"; then
        echo 'AUTOSTART_ENABLED (Wi-Fi configuration callback)'
    else echo 'AUTOSTART_DISABLED_OR_HOOK_CHANGED'; fi
    echo 'Managed process IDs:'
    owned_pids "$FILES"
    echo 'UU processes and connections:'
    ps | grep -E '[u]uplugin|[x]uplugin-guardian' || :
    netstat -anp 2>/dev/null | grep -E 'uuplugin|guardian' || :
}
[ "$(id -u)" = 0 ] || { echo 'Root required'; exit 1; }
case "${1:-status}" in
    start) start_service ;;
    stop) stop_dir "$FILES" ;;
    stop-temporary-for-install) stop_dir /tmp/uu-f7615-test/files ;;
    stop-legacy-for-install) stop_dir "$FILES" ;;
    enable)
        cmp -s "$ROOT/hook.sh" "$HOOK" || { echo 'HOOK_CHANGED; not overwriting it.'; exit 1; }
        : > "$ROOT/enabled"; sync; echo 'AUTOSTART_ENABLED' ;;
    disable) rm -f "$ROOT/enabled"; sync; echo 'AUTOSTART_DISABLED; current process was left running.' ;;
    status) status_service ;;
    log) sed -n '1,160p' "$LOG" ;;
    uninstall)
        [ -f "$ROOT/.uu-f7615-managed-v2" ] || exit 1
        cmp -s "$ROOT/hook.sh" "$HOOK" || { echo 'HOOK_CHANGED; refusing uninstall until reviewed.'; exit 1; }
        rm -f "$ROOT/enabled"
        stop_dir "$FILES" || exit 1
        case "$(cat "$ROOT/hook-before-type")" in
            probe)
                [ -f "$ROOT/hook.before" ] || exit 1
                cp -p "$ROOT/hook.before" "$HOOK" || exit 1 ;;
            absent) rm -f "$HOOK" ;;
            *) echo 'Unknown previous hook; stopped.'; exit 1 ;;
        esac
        # Preserve this entire private installation as a recovery copy.
        : > "$ROOT/uninstalled"
        sync
        echo 'UNINSTALLED: previous hook restored; private files retained for recovery.'
        ;;
    *) echo 'Usage: sh control.sh start|stop|enable|disable|status|log|uninstall'; exit 2 ;;
esac
