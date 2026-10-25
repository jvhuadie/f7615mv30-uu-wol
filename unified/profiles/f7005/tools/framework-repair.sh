#!/bin/sh
set -eu
BASE='@BASE@'
TARGET='@TARGET@'
ORIGINAL=9e919ac97b6421d20701bc6eccf1f52a6a64fbcf352cfdcb39b2b05a9e16f363
FIXED=579c3d851e8e16b81a68f99c74705677be57d69ec49cf4c0e04685e0a68e4936
LOCK=/tmp/ont-andlink-repair.lock
[ "$(id -u)" = 0 ] && [ "$(uname -n)" = F7005MV3 ] || exit 1
echo '453c47535b274071a5ae83d533d825e5072c8b562857e51eeefa8826953180ed  /bin/cspd' | sha256sum -c - >/dev/null
for path in "$BASE" "$TARGET"; do
 p=$path; while [ "$p" != / ]; do [ ! -L "$p" ] || exit 1; p=${p%/*}; [ -n "$p" ] || p=/; done
done
echo "$ORIGINAL  $BASE/andlink-original.jar" | sha256sum -c - >/dev/null
current() { value=$(sha256sum "$TARGET"); echo "${value%% *}"; }
own_lock() { [ ! -L "$LOCK" ] && [ -f "$LOCK/owner" ] && [ ! -L "$LOCK/owner" ] && [ "$(cat "$LOCK/owner")" = "$BASE" ]; }
release_lock() { own_lock || exit 1; rm "$LOCK/owner"; rmdir "$LOCK"; }
java_pids() {
 for d in /proc/[0-9]*; do [ "$(readlink "$d/exe" 2>/dev/null)" != /usr/java/bin/java ] || echo "${d##*/}"; done
}
rollback() {
 value=$(current)
 if [ "$value" = "$ORIGINAL" ]; then
  if [ -f "$TARGET.ont-auto-fix" ] && [ ! -L "$TARGET.ont-auto-fix" ]; then
   echo "$FIXED  $TARGET.ont-auto-fix" | sha256sum -c - >/dev/null && rm "$TARGET.ont-auto-fix"
  fi
  release_lock; echo ALREADY_ORIGINAL; return
 fi
 [ "$value" = "$FIXED" ] || { echo UNKNOWN_TARGET_NOT_OVERWRITTEN; exit 1; }
 [ ! -e "$TARGET.ont-auto-restore" ] && [ ! -L "$TARGET.ont-auto-restore" ] || exit 1
 cp -p "$BASE/andlink-original.jar" "$TARGET.ont-auto-restore"
 echo "$ORIGINAL  $TARGET.ont-auto-restore" | sha256sum -c - >/dev/null
 mv "$TARGET.ont-auto-restore" "$TARGET"; sync
 for pid in $(java_pids); do kill -TERM "$pid" 2>/dev/null || true; done
 release_lock
 echo ORIGINAL_RESTORED
}
case "${1:-}" in
 arm)
  [ "$(current)" = "$ORIGINAL" ] && [ ! -e "$BASE/armed" ] || exit 1
  mkdir -m 700 "$LOCK"; echo "$BASE" > "$LOCK/owner"
  : > "$BASE/armed"
  sh -c 'trap "" HUP; sleep 180; if [ ! -f "$1/accepted" ]; then sh "$1/framework-repair.sh" watch-rollback; fi' sh "$BASE" </dev/null >"$BASE/watchdog.log" 2>&1 &
  echo "$!" > "$BASE/watchdog.pid";;
 apply)
  [ -f "$BASE/armed" ] && [ "$(current)" = "$ORIGINAL" ] || exit 1
  own_lock || exit 1
  echo "$FIXED  $BASE/andlink-fixed.jar" | sha256sum -c - >/dev/null
  [ ! -e "$TARGET.ont-auto-fix" ] && [ ! -L "$TARGET.ont-auto-fix" ] || exit 1
  cp -p "$TARGET" "$TARGET.ont-auto-fix"
  cat "$BASE/andlink-fixed.jar" > "$TARGET.ont-auto-fix"
  echo "$FIXED  $TARGET.ont-auto-fix" | sha256sum -c - >/dev/null
  # Do not terminate a working Java framework to apply a speculative repair.
  n=0; while [ "$n" -lt 45 ]; do
   if [ -z "$(java_pids)" ]; then
    [ "$(current)" = "$ORIGINAL" ] || exit 1
    mv "$TARGET.ont-auto-fix" "$TARGET"; sync; echo PATCH_APPLIED; exit 0
   fi
   n=$((n+1)); sleep 1
  done
  rm "$TARGET.ont-auto-fix"; echo NO_JAVA_IDLE_WINDOW; exit 1;;
 accept)
  [ "$(current)" = "$FIXED" ] && [ -f "$BASE/armed" ] || exit 1
  own_lock || exit 1
  : > "$BASE/accepted"; sync; release_lock; echo REPAIR_ACCEPTED;;
 rollback)
  if [ ! -e "$LOCK" ] && [ ! -L "$LOCK" ]; then mkdir -m 700 "$LOCK"; echo "$BASE" > "$LOCK/owner"; fi
  own_lock || exit 1; rollback;;
 watch-rollback) own_lock || exit 0; rollback;;
 *) echo 'usage: arm | apply | accept | rollback'; exit 2;;
esac
