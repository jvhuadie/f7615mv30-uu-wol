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
__SERVICE_FUNCTIONS__
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
__EMBED_SERVICE_SCRIPTS__
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
