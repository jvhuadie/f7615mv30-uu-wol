#!/bin/sh
# F7615MV30-only installer. Generated with embedded service scripts.
set -eu
PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH
umask 077
ROOT=/usr/plugin/uu-wol-f7615
STAGE=/usr/plugin/uu-wol-f7615.installing
OLD=/usr/plugin/uu-wol-f7615.before-v2
WORK=/tmp/uu-f7615-v2-installer
HOOK=/wlan/wifi_debug.sh
PKGHASH=590006073430b2b1ca441615482e4eef2d7bce0cebc455f486a76c9da60569e5
fail() { echo "ERROR: $*" >&2; exit 1; }
write_service_scripts() {
SERVICE_DIR=$1
cat > "$SERVICE_DIR/control.sh" <<'UU_CONTROL_EOF'
#!/bin/sh
set -u
PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH
umask 077
ROOT=/usr/plugin/uu-wol-f7615
FILES=$ROOT/files
LOG=/tmp/uu-f7615-service.log
LOGGER_PID=/tmp/uu-f7615-log-writer.pid
HOOK=/wlan/wifi_debug.sh
LOCK=/tmp/uu-f7615-start.lock
owned_pids() {
    for entry in /proc/[0-9]*; do
        exe=$(readlink "$entry/exe" 2>/dev/null) || continue
        case "$exe" in "$1/uuplugin"|"$1/xuplugin-guardian")
            [ -z "${2:-}" ] || [ "${exe##*/}" = "$2" ] || continue
            echo "${entry##*/}" ;;
        esac
    done
}
logger_pid() {
    pid=$(cat "$LOGGER_PID" 2>/dev/null || echo '')
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ -r "/proc/$pid/cmdline" ] || return 1
    grep -aqF "$ROOT/log-writer.sh" "/proc/$pid/cmdline" || return 1
    echo "$pid"
}
stop_logger() {
    pid=$(logger_pid 2>/dev/null || echo '')
    [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || :
}
stop_dir() {
    pids=$(owned_pids "$1")
    [ -n "$pids" ] || return 0
    for pid in $pids; do kill -STOP "$pid" 2>/dev/null || :; done
    for pid in $pids; do kill -TERM "$pid" 2>/dev/null || :; done
    for pid in $pids; do kill -CONT "$pid" 2>/dev/null || :; done
    sleep 3
    [ -z "$(owned_pids "$1")" ] || { echo 'STOP_INCOMPLETE; no PID file was removed.' >&2; return 1; }
    [ "$1" != "$FILES" ] || stop_logger
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
    stop_logger
    if ps | grep '[u]uplugin .*uu.conf' >/dev/null; then
        echo 'FOREIGN_UU_RUNNING: refusing a duplicate instance.' >&2
        return 1
    fi
    # Vendor initialization changes /usr/plugin ownership on every boot.
    chown -R root:root "$ROOT" || return 1
    chmod 700 "$ROOT" "$FILES" || return 1
    sh -c 'trap "" HUP; cd /usr/plugin/uu-wol-f7615/files || exit 1; ./uuplugin ./uu.conf 2>&1 | sh /usr/plugin/uu-wol-f7615/log-writer.sh' </dev/null >/dev/null 2>&1 &
    sleep 5
    if [ -z "$(owned_pids "$FILES" uuplugin)" ]; then
        echo 'START_FAILED'; sed -n '1,100p' "$LOG"; return 1
    fi
    if [ -z "$(logger_pid 2>/dev/null || echo '')" ]; then
        echo 'LOG_WRITER_NOT_RUNNING; UU may still be online. Inspect storage permissions.' >&2
        return 1
    fi
    echo 'PROCESS_STARTED; cloud and remote-wake validation are still required.'
}
status_service() {
    echo 'VERSION=0.3'
    if [ -f "$ROOT/enabled" ] && cmp -s "$ROOT/hook.sh" "$HOOK"; then
        echo 'AUTOSTART_ENABLED (Wi-Fi configuration callback)'
    else echo 'AUTOSTART_DISABLED_OR_HOOK_CHANGED'; fi
    echo 'Managed process IDs:'
    owned_pids "$FILES"
    echo 'Log limits: current <=256 KiB; previous <=256 KiB; stored in /tmp.'
    echo "Log writer PID: $(logger_pid 2>/dev/null || echo NOT_RUNNING)"
    ls -l "$LOG" "$LOG.previous" 2>/dev/null || :
    echo 'UU processes and connections:'
    ps | grep -E '[u]uplugin|[x]uplugin-guardian' || :
    netstat -anp 2>/dev/null | grep -E 'uuplugin|guardian' || :
}
[ "$(id -u)" = 0 ] || { echo 'Root required'; exit 1; }
case "${1:-status}" in
    start) start_service ;;
    stop) stop_dir "$FILES" && stop_logger ;;
    is-running) [ -n "$(owned_pids "$FILES" uuplugin)" ] ;;
    stop-temporary-for-install) stop_dir /tmp/uu-f7615-test/files ;;
    stop-legacy-for-install) stop_dir "$FILES" ;;
    enable)
        cmp -s "$ROOT/hook.sh" "$HOOK" || { echo 'HOOK_CHANGED; not overwriting it.'; exit 1; }
        : > "$ROOT/enabled"; sync; echo 'AUTOSTART_ENABLED' ;;
    disable) rm -f "$ROOT/enabled"; sync; echo 'AUTOSTART_DISABLED; current process was left running.' ;;
    status) status_service ;;
    log)
        for file in "$LOG.previous" "$LOG"; do
            [ ! -f "$file" ] || { echo "=== $file ==="; sed -n '1,160p' "$file"; }
        done ;;
    uninstall)
        [ -f "$ROOT/.uu-f7615-managed-v2" ] || exit 1
        cmp -s "$ROOT/hook.sh" "$HOOK" || { echo 'HOOK_CHANGED; refusing uninstall until reviewed.'; exit 1; }
        rm -f "$ROOT/enabled"
        stop_dir "$FILES" || exit 1
        stop_logger
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
UU_CONTROL_EOF
cat > "$SERVICE_DIR/hook.sh" <<'UU_HOOK_EOF'
#!/bin/sh
# UU_F7615_AUTOSTART_V2
umask 077
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
UU_HOOK_EOF
cat > "$SERVICE_DIR/log-writer.sh" <<'UU_LOGGER_EOF'
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
UU_LOGGER_EOF
}
# Included by the generated installer; only known v0.2 scripts are upgraded.
upgrade_service() {
    [ ! -f "$ROOT/uninstalled" ] || fail 'Uninstalled private directory retained; review required.'
    [ ! -L "$ROOT" ] && [ ! -L "$HOOK" ] || fail 'Unexpected symlink.'
    cmp -s "$ROOT/hook.sh" "$HOOK" || fail 'Active boot hook changed; refusing overwrite.'
    [ ! -e "$STAGE" ] && [ ! -L "$STAGE" ] || fail 'Staging directory already exists.'
    mkdir "$STAGE"
    : > "$STAGE/.uu-f7615-managed-v2"
    write_service_scripts "$STAGE"
    upgrade_restore=no
    upgrade_running=no
    upgrade_enabled=no
    BACKUP=$ROOT/backup-before-v0.3
    upgrade_cleanup() {
        result=$?
        trap - 0
        set +e
        if [ "$upgrade_restore" = yes ]; then
            sh "$STAGE/control.sh" stop
            cp -p "$BACKUP/control.sh" "$ROOT/control.sh"
            cp -p "$BACKUP/hook.sh" "$ROOT/hook.sh"
            cp -p "$BACKUP/hook.active" "$HOOK"
            rm -f "$ROOT/log-writer.sh" "$ROOT/version"
            sync
            echo 'UPGRADE_FAILED: previous scripts restored; original binding retained.' >&2
            if [ "$upgrade_running" = yes ] || [ "$upgrade_enabled" = yes ]; then
                sh "$ROOT/control.sh" start
            fi
        fi
        if [ -d "$STAGE" ] && [ ! -L "$STAGE" ] && [ -f "$STAGE/.uu-f7615-managed-v2" ]; then
            rm -rf /usr/plugin/uu-wol-f7615.installing
        fi
        exit "$result"
    }
    trap upgrade_cleanup 0
    if cmp -s "$STAGE/control.sh" "$ROOT/control.sh" &&
       cmp -s "$STAGE/hook.sh" "$ROOT/hook.sh" &&
       cmp -s "$STAGE/log-writer.sh" "$ROOT/log-writer.sh"; then
        echo 'ALREADY_INSTALLED v0.3; private files left unchanged.'
        sh "$ROOT/control.sh" status
        return 0
    fi
    echo '4041c66104c7ffc9c7aeddb37a5465a9523488698bcb97a420adbf6e0bc39327  '"$ROOT/control.sh" | sha256sum -c - || fail 'Modified or unsupported previous control script.'
    echo '1a6ccdbb411a7d23643db58aef14fc264496262c3d154d8cd1dfd2ab824887d4  '"$ROOT/hook.sh" | sha256sum -c - || fail 'Modified or unsupported previous hook script.'
    for file in control.sh hook.sh; do
        [ -f "$ROOT/$file" ] && [ ! -L "$ROOT/$file" ] || fail 'Unexpected previous script type.'
    done
    [ ! -e "$ROOT/log-writer.sh" ] && [ ! -L "$ROOT/log-writer.sh" ] || fail 'Unknown existing log writer.'
    if [ -e "$BACKUP" ] || [ -L "$BACKUP" ]; then
        [ ! -L "$BACKUP" ] &&
        cmp -s "$BACKUP/control.sh" "$ROOT/control.sh" &&
        cmp -s "$BACKUP/hook.sh" "$ROOT/hook.sh" &&
        cmp -s "$BACKUP/hook.active" "$HOOK" || fail 'Previous upgrade backup differs; review required.'
    else
        mkdir "$BACKUP"
        cp -p "$ROOT/control.sh" "$BACKUP/control.sh"
        cp -p "$ROOT/hook.sh" "$BACKUP/hook.sh"
        cp -p "$HOOK" "$BACKUP/hook.active"
    fi
    [ ! -f "$ROOT/enabled" ] || upgrade_enabled=yes
    if sh "$STAGE/control.sh" is-running; then upgrade_running=yes; fi
    # New process matching includes guardian even when it changes its cwd to /.
    sh "$STAGE/control.sh" stop
    upgrade_restore=yes
    for name in control.sh hook.sh log-writer.sh; do
        cp "$STAGE/$name" "$ROOT/$name.new"
        chmod 700 "$ROOT/$name.new"
        mv -f "$ROOT/$name.new" "$ROOT/$name"
    done
    cp "$ROOT/hook.sh" "$HOOK.new"
    chmod 700 "$HOOK.new"
    mv -f "$HOOK.new" "$HOOK"
    echo '0.3' > "$ROOT/version"
    sync
    if [ "$upgrade_running" = yes ] || [ "$upgrade_enabled" = yes ]; then
        sh "$ROOT/control.sh" start
    fi
    upgrade_restore=no
    echo 'UPGRADE_COMPLETE v0.3: scripts updated, binaries and binding retained. No router reboot required.'
    sh "$ROOT/control.sh" status
}
[ "$(id -u)" = 0 ] || fail 'Root required.'
[ "$(uname -m)" = aarch64 ] || fail 'Only aarch64 is supported.'
echo '58a5a48a3bfb5bd38209ffa58e3fb5b635623d4a2125799cd8e7e897e3a6a58f  /bin/cspd' | sha256sum -c - || fail 'Unverified firmware: cspd fingerprint differs.'
grep -q ' /usr/plugin ubifs rw,' /proc/mounts || fail 'Writable plugin partition missing.'
grep -q ' /wlan jffs2 rw,' /proc/mounts || fail 'Writable WLAN partition missing.'
for app in sha256sum readlink cmp dd wc; do which "$app" >/dev/null 2>&1 || fail "Missing $app"; done
if [ -f "$ROOT/.uu-f7615-managed-v2" ]; then
    upgrade_service
    exit $?
fi
if [ -e "$ROOT" ] || [ -L "$ROOT" ]; then
    [ ! -L "$ROOT" ] && [ -f "$ROOT/.uu-f7615-managed-v1" ] || fail 'Unmanaged destination exists.'
fi
[ ! -e "$STAGE" ] && [ ! -L "$STAGE" ] || fail 'Staging directory exists; inspect it before retrying.'
[ ! -e "$OLD" ] && [ ! -L "$OLD" ] || fail 'Previous-version backup exists; inspect it before retrying.'
HOOKTYPE=absent
if [ -e "$HOOK" ] || [ -L "$HOOK" ]; then
    [ ! -L "$HOOK" ] && [ -f "$HOOK" ] || fail 'Hook is not a regular file.'
    grep -q '^# UU_F7615_BOOT_PROBE_V1$' "$HOOK" || fail 'Existing hook is not our probe; refusing overwrite.'
    HOOKTYPE=probe
fi
AVAILABLE=$(df -k /usr/plugin | awk 'END {print $4}')
[ "$AVAILABLE" -ge 17000 ] || fail 'At least 17000 KiB free plugin space required for safe staging and recovery.'
for app in curl tar sha256sum readlink cmp dd wc; do which "$app" >/dev/null 2>&1 || fail "Missing $app"; done
mkdir "$WORK" || fail 'Installer temporary directory exists.'
mkdir "$STAGE"
: > "$STAGE/.uu-f7615-managed-v2"
cleanup() {
    rm -f "$WORK/uu.tar.gz"
    rmdir "$WORK" 2>/dev/null || :
    if [ -d "$STAGE" ] && [ ! -L "$STAGE" ] && [ -f "$STAGE/.uu-f7615-managed-v2" ]; then
        rm -rf /usr/plugin/uu-wol-f7615.installing
    fi
}
trap cleanup 0
if [ -f /tmp/uu-f7615-test/uu.tar.gz ]; then
    cp /tmp/uu-f7615-test/uu.tar.gz "$WORK/uu.tar.gz"
else
    curl -kfL --connect-timeout 15 --max-time 180 \
    'https://uurouter.gdl.netease.com/uuplugin/openwrt-aarch64/v14.10.6/uu.tar.gz?key1=4b409889d5287da200636313b0db0a47&key2=6adc7e40' \
    -o "$WORK/uu.tar.gz" || fail 'Download failed; no boot hook was changed.'
fi
echo "$PKGHASH  $WORK/uu.tar.gz" | sha256sum -c - || fail 'Official package checksum mismatch.'
mkdir "$STAGE/files"
tar -xzf "$WORK/uu.tar.gz" -C "$STAGE/files"
SOURCE=''
if [ -f /tmp/uu-f7615-test/files/.uuplugin_uuid ]; then SOURCE=/tmp/uu-f7615-test/files
elif [ -f "$ROOT/files/.uuplugin_uuid" ]; then SOURCE=$ROOT/files
elif [ -s /usr/plugin/uu-wol-backup/working-backup.tar.gz ]; then
    # This is the local owner's private backup; it is never distributed.
    mkdir "$STAGE/recovery"
    tar -xzf /usr/plugin/uu-wol-backup/working-backup.tar.gz -C "$STAGE/recovery" || fail 'Local backup extraction failed.'
    SOURCE=$STAGE/recovery
fi
if [ -n "$SOURCE" ]; then
    for name in .sn .uuplugin_uuid uu.conf; do
        [ ! -L "$SOURCE/$name" ] || fail 'Unexpected symlink in private state.'
        [ ! -f "$SOURCE/$name" ] || cp -p "$SOURCE/$name" "$STAGE/files/$name"
    done
    echo 'LOCAL_BINDING_PRESERVED'
else echo 'CLEAN_INSTALL: bind your own UU account after starting.'; fi
if [ -d "$STAGE/recovery" ]; then rm -rf /usr/plugin/uu-wol-f7615.installing/recovery; fi
write_service_scripts "$STAGE"
echo '0.3' > "$STAGE/version"
echo "$HOOKTYPE" > "$STAGE/hook-before-type"
[ "$HOOKTYPE" != probe ] || cp -p "$HOOK" "$STAGE/hook.before"
chmod 700 "$STAGE" "$STAGE/files" "$STAGE/control.sh" "$STAGE/hook.sh" "$STAGE/log-writer.sh"
chmod 700 "$STAGE/files/uuplugin" "$STAGE/files/xuplugin-guardian" "$STAGE/files/xtables-nft-multi"
chmod 600 "$STAGE/files/uu.conf"
# Stop only the known temporary/legacy instances, never arbitrary router services.
sh "$STAGE/control.sh" stop-temporary-for-install
if [ -e "$ROOT" ]; then
    sh "$STAGE/control.sh" stop-legacy-for-install
fi
# Capture any final state writes after stopping the old instances.
case "$SOURCE" in /tmp/uu-f7615-test/files|/usr/plugin/uu-wol-f7615/files)
    for name in .sn .uuplugin_uuid uu.conf; do
        [ ! -L "$SOURCE/$name" ] || fail 'Unexpected state symlink.'
        [ ! -f "$SOURCE/$name" ] || cp -p "$SOURCE/$name" "$STAGE/files/$name"
    done ;;
esac
if [ -e "$ROOT" ]; then mv "$ROOT" "$OLD"; fi
mv "$STAGE" "$ROOT"
cp "$ROOT/hook.sh" "$HOOK"
chmod 700 "$HOOK"
: > "$ROOT/enabled"
sync
echo 'AUTOSTART_INSTALLED: starting UU now; keep this terminal open for the result.'
sh "$ROOT/control.sh" start
sh "$ROOT/control.sh" status
echo 'NEXT: verify original UU device online, then reboot router and test mobile-data remote wake.'
