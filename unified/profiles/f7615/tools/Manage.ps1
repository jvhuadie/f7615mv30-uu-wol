function Get-UuStateCommand {
    return 'ROOT=/usr/plugin/uu-wol-f7615; if [ ! -f "$ROOT/.uu-f7615-managed-v2" ] || [ ! -f "$ROOT/control.sh" ]; then echo UU_INSTALL=MISSING; echo UU_RUNNING=NO; else if [ -f "$ROOT/uninstalled" ]; then echo UU_INSTALL=UNINSTALLED; else echo UU_INSTALL=INSTALLED; fi; if sh "$ROOT/control.sh" is-running; then echo UU_RUNNING=YES; else echo UU_RUNNING=NO; fi; fi; if [ ! -f "$ROOT/enabled" ]; then echo UU_AUTOSTART=DISABLED; elif cmp -s "$ROOT/hook.sh" /wlan/wifi_debug.sh; then echo UU_AUTOSTART=ENABLED; else echo UU_AUTOSTART=HOOK_CHANGED; fi; v=$(cat "$ROOT/version" 2>/dev/null || echo ""); echo UU_VERSION=$v'
}
function Get-UuManagementGuard {
    return '( set -e; ROOT=/usr/plugin/uu-wol-f7615; [ ! -L "$ROOT" ] && [ -f "$ROOT/.uu-f7615-managed-v2" ] && [ ! -L "$ROOT/control.sh" ] && [ ! -L "$ROOT/hook.sh" ] && [ ! -L "$ROOT/enabled" ] && [ ! -L "$ROOT/uninstalled" ] && [ ! -L "$ROOT/hook-before-type" ] && [ ! -L "$ROOT/hook.before" ] && [ ! -L /wlan/wifi_debug.sh ] || exit 1; echo "789a19a789781e661013362c6ce1dfed6fca7c3717659f6389131485528567af  $ROOT/control.sh" | sha256sum -c - >/dev/null; echo "ed636266d90d888f4a2505eeca59484c7b732dc3cf36274d7001e808630fa7a7  $ROOT/hook.sh" | sha256sum -c - >/dev/null )'
}
function Protect-UuManagementCommand([string]$Command) {
    return '( umask 077; if ! mkdir /tmp/uu-f7615-manage.lock 2>/dev/null; then echo MANAGEMENT_BUSY; exit 1; fi; trap ''rmdir /tmp/uu-f7615-manage.lock 2>/dev/null || :'' 0; ' + $Command + ' )'
}
function Get-UuRestoreCommand {
    # Restore only a known retained installation after our own uninstall.
    # Refuse an active hook that no longer matches the saved pre-install state.
    $parts = @(
        '( set -eu; ROOT=/usr/plugin/uu-wol-f7615; HOOK=/wlan/wifi_debug.sh;',
        '[ -f "$ROOT/uninstalled" ] && [ ! -L "$HOOK" ] && [ ! -L "$ROOT/hook-before-type" ] || exit 1;',
        'if sh "$ROOT/control.sh" is-running; then echo UNEXPECTED_RUNNING_INSTANCE; exit 1; fi;',
        'kind=$(cat "$ROOT/hook-before-type"); case "$kind" in',
        'probe) [ -f "$ROOT/hook.before" ] && [ ! -L "$ROOT/hook.before" ] || exit 1; cmp -s "$ROOT/hook.before" "$HOOK" || { echo HOOK_CHANGED; exit 1; } ;;',
        'absent) [ ! -e "$HOOK" ] || { echo HOOK_CHANGED; exit 1; } ;;',
        '*) echo UNKNOWN_PREVIOUS_HOOK; exit 1 ;; esac;',
        'rollback() { result=$?; trap - 0; set +e;',
        'sh "$ROOT/control.sh" stop || { echo RESTORE_STOP_FAILED_REVIEW_REQUIRED; exit 1; };',
        'cmp -s "$ROOT/hook.sh" "$HOOK" || { echo RESTORE_HOOK_CHANGED_REVIEW_REQUIRED; exit 1; };',
        'case "$kind" in probe) cp -p "$ROOT/hook.before" "$HOOK" || exit 1 ;; absent) rm -f "$HOOK" || exit 1 ;; esac;',
        'rm -f "$ROOT/enabled" || exit 1; : >"$ROOT/uninstalled"; [ -f "$ROOT/uninstalled" ] && [ ! -f "$ROOT/enabled" ] || exit 1; sync || exit 1; echo RESTORE_ROLLED_BACK; exit "$result"; };',
        'trap rollback 0; cp -p "$ROOT/hook.sh" "$HOOK"; : >"$ROOT/enabled"; rm -f "$ROOT/uninstalled"; sync;',
        'sh "$ROOT/control.sh" start; trap - 0; echo RESTORED_WITH_BINDING )'
    )
    return $parts -join ' '
}
