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
