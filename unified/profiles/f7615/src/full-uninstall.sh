#!/bin/sh
# Uploaded only for explicitly selected full removal; never installed as a service.
set -eu
umask 077
PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH
ROOT=/usr/plugin/uu-wol-f7615
BACKUP=/usr/plugin/uu-wol-backup
OLD=/usr/plugin/uu-wol-f7615.before-v2
STAGE=/usr/plugin/uu-wol-f7615.installing
TEST=/tmp/uu-f7615-test
HOOK=/wlan/wifi_debug.sh
PROC=/proc
MOUNTS=/proc/mounts
WORK=/tmp/uu-f7615-full-check.$$
fail() { echo "FULL_REMOVE_REFUSED:$1" >&2; exit 1; }
[ "$#" = 1 ] || fail CONFIRMATION_REQUIRED
case "$1" in --confirmed-full|--preflight) ;; *) fail CONFIRMATION_REQUIRED ;; esac
MODE=$1
[ "$(id -u)" = 0 ] || fail ROOT_REQUIRED
[ "$(uname -m)" = aarch64 ] || fail PLATFORM_MISMATCH
echo '58a5a48a3bfb5bd38209ffa58e3fb5b635623d4a2125799cd8e7e897e3a6a58f  /bin/cspd' | sha256sum -c - >/dev/null || fail FIRMWARE_MISMATCH

check_tree() {
    [ -d "$1" ] && [ ! -L "$1" ] || fail DIRECTORY_TYPE
    [ "$(readlink -f "$1")" = "$1" ] || fail DIRECTORY_PATH
    if grep -F " $1/" "$MOUNTS" >/dev/null || grep -F " $1 " "$MOUNTS" >/dev/null; then fail NESTED_MOUNT; fi
    links=$(find "$1" -type l -print) || fail DIRECTORY_READ
    [ -z "$links" ] || fail SYMLINK_PRESENT
}
[ -r "$MOUNTS" ] || fail MOUNT_TABLE_UNAVAILABLE
check_tree "$ROOT"
[ -f "$ROOT/.uu-f7615-managed-v2" ] || fail UNKNOWN_INSTALLATION
echo "789a19a789781e661013362c6ce1dfed6fca7c3717659f6389131485528567af  $ROOT/control.sh" | sha256sum -c - >/dev/null || fail MODIFIED_CONTROL
echo "ed636266d90d888f4a2505eeca59484c7b732dc3cf36274d7001e808630fa7a7  $ROOT/hook.sh" | sha256sum -c - >/dev/null || fail MODIFIED_HOOK
[ ! -e "$STAGE" ] && [ ! -L "$STAGE" ] || fail INSTALLER_STAGE_PRESENT
[ ! -e /tmp/uu-f7615-start.lock ] || fail START_IN_PROGRESS
[ ! -L "$HOOK" ] || fail UNKNOWN_HOOK
kind=$(cat "$ROOT/hook-before-type")
case "$kind" in
    probe)
        [ -f "$ROOT/hook.before" ] || fail MISSING_HOOK_BACKUP
        grep -q '^# UU_F7615_BOOT_PROBE_V1$' "$ROOT/hook.before" || fail UNKNOWN_ORIGINAL_HOOK
        ;;
    absent) ;;
    *) fail UNKNOWN_ORIGINAL_HOOK ;;
esac
if [ -f "$ROOT/uninstalled" ]; then
    case "$kind" in
        probe) cmp -s "$ROOT/hook.before" "$HOOK" || fail HOOK_CHANGED ;;
        absent) [ ! -e "$HOOK" ] || fail HOOK_CHANGED ;;
    esac
else
    cmp -s "$ROOT/hook.sh" "$HOOK" || fail HOOK_CHANGED
fi

[ ! -e "$WORK" ] && [ ! -L "$WORK" ] || fail TEMP_PATH_BUSY
mkdir "$WORK"
trap 'rm -f "$WORK/index"; rmdir "$WORK" 2>/dev/null || :' 0
check_archive() {
    [ -f "$1" ] && [ ! -L "$1" ] || fail BACKUP_TYPE
    tar -tzf "$1" >"$WORK/index" || fail BACKUP_ARCHIVE_INVALID
    sn=0; uuid=0; program=0; marker=0
    while IFS= read -r entry; do
        case "$entry" in /*|../*|*/../*|*/..|..) fail BACKUP_PATH ;; esac
        entry=${entry#./}
        case "$2:$entry" in
            working:|working:./) ;;
            working:.sn) sn=1 ;;
            working:.uuplugin_uuid) uuid=1 ;;
            working:uuplugin) program=1 ;;
            working:uu.conf|working:xuplugin-guardian|working:xtables-nft-multi) ;;
            baseline:usr/plugin/uu-wol-f7615/.uu-f7615-managed-v2) marker=1 ;;
            baseline:usr/plugin/uu-wol-f7615|baseline:usr/plugin/uu-wol-f7615/*|baseline:wlan/wifi_debug.sh) ;;
            *) fail BACKUP_CONTENT_UNKNOWN ;;
        esac
    done <"$WORK/index"
    if [ "$2" = working ]; then [ "$sn$uuid$program" = 111 ] || fail BACKUP_NOT_OWNED
    else [ "$marker" = 1 ] || fail BACKUP_NOT_OWNED; fi
}
if [ -e "$BACKUP" ] || [ -L "$BACKUP" ]; then
    check_tree "$BACKUP"
    for path in "$BACKUP"/* "$BACKUP"/.[!.]* "$BACKUP"/..?*; do
        [ -e "$path" ] || continue
        case "${path##*/}" in
            working-backup.tar.gz) check_archive "$path" working ;;
            game-research-[0-9]*)
                check_tree "$path"
                [ -f "$path/baseline.tar.gz" ] || fail BACKUP_LAYOUT_UNKNOWN
                for file in "$path"/* "$path"/.[!.]* "$path"/..?*; do
                    [ -e "$file" ] || continue
                    [ -f "$file" ] || fail BACKUP_LAYOUT_UNKNOWN
                    case "${file##*/}" in
                        baseline.tar.gz|baseline.tar.gz.sha256|all-files.sha256|before.sha256|archive-files.txt|boot-id.txt|status.txt|recover.sh|ip-rules.txt|ip-routes.txt|iptables-filter.txt|iptables-nat.txt|iptables-mangle.txt) ;;
                        *) fail BACKUP_LAYOUT_UNKNOWN ;;
                    esac
                done
                check_archive "$path/baseline.tar.gz" baseline
                ;;
            *) fail BACKUP_LAYOUT_UNKNOWN ;;
        esac
    done
fi
if [ -e "$OLD" ] || [ -L "$OLD" ]; then
    check_tree "$OLD"
    [ -f "$OLD/.uu-f7615-managed-v1" ] || [ -f "$OLD/.uu-f7615-managed-v2" ] || fail UNKNOWN_LEGACY_COPY
fi
if [ -e "$TEST" ] || [ -L "$TEST" ]; then
    check_tree "$TEST"
    [ -f "$TEST/files/.uuplugin_uuid" ] && [ -f "$TEST/files/uuplugin" ] || fail UNKNOWN_TEST_COPY
fi
for entry in "$PROC"/[0-9]*; do
    exe=$(readlink "$entry/exe" 2>/dev/null) || continue
    case "$exe" in "$OLD"/*|"$TEST"/*) fail LEGACY_PROCESS_RUNNING ;; esac
done
echo FULL_UNINSTALL_PREFLIGHT_OK
[ "$MODE" != --preflight ] || exit 0

# All directory/archive/entry checks above precede any service changes.
if [ -f "$ROOT/uninstalled" ]; then sh "$ROOT/control.sh" stop
else sh "$ROOT/control.sh" uninstall; fi
[ -f "$ROOT/uninstalled" ] && [ ! -f "$ROOT/enabled" ] || fail UNINSTALL_NOT_CONFIRMED
for entry in "$PROC"/[0-9]*; do
    exe=$(readlink "$entry/exe" 2>/dev/null) || continue
    case "$exe" in "$ROOT"/*|"$OLD"/*|"$TEST"/*) fail OWNED_PROCESS_STILL_RUNNING ;; esac
done
case "$kind" in
    probe)
        cmp -s "$ROOT/hook.before" "$HOOK" || fail HOOK_CHANGED
        rm -f "$HOOK"
        ;;
    absent) [ ! -e "$HOOK" ] || fail HOOK_CHANGED ;;
esac
echo FULL_UNINSTALL_SERVICE_REMOVED
# Recheck exact canonical directories immediately before each recursive delete.
for target in "$BACKUP" "$OLD" "$TEST"; do
    [ -e "$target" ] || continue
    check_tree "$target"
    case "$target" in "$BACKUP"|"$OLD"|"$TEST") rm -rf "$target" ;; *) fail DELETE_TARGET ;; esac
done
check_tree "$ROOT"
[ -f "$ROOT/.uu-f7615-managed-v2" ] && [ -f "$ROOT/uninstalled" ] || fail INSTALLATION_CHANGED
rm -rf "$ROOT"
rm -f /tmp/uu-f7615-service.log /tmp/uu-f7615-service.log.previous /tmp/uu-f7615-log-writer.pid /tmp/uu-f7615-boot.log /tmp/uu-f7615-boot-probe.log /tmp/uu-f7615-install.sh /tmp/uu-f7615-rotation-test.log /tmp/uu-f7615-rotation-test.log.previous /tmp/uu-f7615-rotation-test.pid
sync
[ ! -e "$ROOT" ] && [ ! -e "$BACKUP" ] && [ ! -e "$OLD" ] && [ ! -e "$TEST" ] || fail CLEANUP_INCOMPLETE
echo FULL_UNINSTALL_COMPLETE
