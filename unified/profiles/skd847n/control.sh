#!/bin/sh
set -eu
BASE=/usr/data/uu-wol-skd847n
NAME=local.ont.uuwol.skd847n
fail() { echo "$1" >&2; exit 1; }
safe_path() { p=$1; while [ "$p" != / ]; do [ ! -L "$p" ] || fail SYMLINK_PATH; p=${p%/*}; [ -n "$p" ] || p=/; done; }
[ "$(id -u)" = 0 ] && [ "$(uname -n)" = skyworth ] && [ "$(uname -m)" = aarch64 ] || fail DEVICE_MISMATCH
echo '4864d4dc6118f9aa5eed96f99538877c16742d10de43f78e66ee4aba7f4e1fa5  /bin/cspd' | sha256sum -c - >/dev/null || fail FIRMWARE_MISMATCH
safe_path "$BASE"
[ -f "$BASE/managed-v1" ] && [ "$(cat "$BASE/managed-v1")" = SK_D847N_MANAGED_V1 ] || fail NOT_MANAGED
for name in service.jar uuplugin xuplugin-guardian launch-uu; do [ -f "$BASE/$name" ] && [ ! -L "$BASE/$name" ] || fail INVALID_FILE; done
cd "$BASE"
echo '75c95271ab6139d11498f38a97061901e93ec6480c982975b841f3aa646ba445  service.jar' | sha256sum -c - >/dev/null || fail PAYLOAD_CHANGED
echo 'd6824574d49e3f98a78b33c1bb0a41eb9e1082977439c7eeef85229867e6c34d  uuplugin' | sha256sum -c - >/dev/null || fail PAYLOAD_CHANGED
echo '464fdb577e7a23d46a3ae7372205bed3162dc40fa29868626496a012e40471f6  xuplugin-guardian' | sha256sum -c - >/dev/null || fail PAYLOAD_CHANGED
echo '2a0f7139fe4ee719a5e728e94273104b26e2f9ddfeeb82bd64d610b39b311d68  launch-uu' | sha256sum -c - >/dev/null || fail PAYLOAD_CHANGED
[ "$(stat -c '%u:%g:%a' "$BASE")" = 0:0:755 ] || fail PROJECT_DIRECTORY_CHANGED
mode=$(stat -c '%u:%g:%a:%h' "$BASE/launch-uu")
if [ "$mode" != 0:0:4555:1 ]; then
 [ -f "$BASE/uninstalled" ] && [ ! -L "$BASE/uninstalled" ] && [ "$mode" = 0:0:500:1 ] || fail LAUNCHER_PERMISSIONS_CHANGED
fi
count=0
for f in /usr/data/o_ins/felix-cache/bundle*/bundle.info; do
 [ -f "$f" ] && [ ! -L "$f" ] || continue
 if [ "$(sed -n 2p "$f")" = "file:$BASE/service.jar" ]; then count=$((count+1)); DIR=${f%/bundle.info}; fi
done
[ "$count" = 1 ] || fail REGISTRATION_NOT_UNIQUE
safe_path "$DIR"
echo '75c95271ab6139d11498f38a97061901e93ec6480c982975b841f3aa646ba445  '$DIR/version0.0/bundle.jar | sha256sum -c - >/dev/null || fail CACHED_JAR_CHANGED
DATA=$DIR/data
owned() {
 for f in /proc/[0-9]*/exe; do
  e=$(readlink "$f" 2>/dev/null) || continue
  case "$e" in "$BASE/uuplugin"|"$BASE/xuplugin-guardian")
   [ "$f" -ef "$BASE/uuplugin" ] || [ "$f" -ef "$BASE/xuplugin-guardian" ] || continue
   pid=${f#/proc/};pid=${pid%/exe}
   grep -q '^Uid:[[:space:]]*107[[:space:]]*107[[:space:]]*107[[:space:]]*107' "/proc/$pid/status" || fail UNEXPECTED_PROCESS_UID
   echo "$pid";;
  esac
 done
}
stop_service() {
 held=no
 if [ -f /var/run/uuplugin.pid ] && [ ! -L /var/run/uuplugin.pid ]; then
  for pid in $(owned); do
   for f in /proc/"$pid"/fd/*; do
    if [ "$f" -ef /var/run/uuplugin.pid ]; then
     exec 9</var/run/uuplugin.pid
     if [ "$f" -ef /proc/$$/fd/9 ]; then held=yes; break 2; else exec 9<&-; fi
    fi
   done
  done
 fi
 /bin/sidbg 74 osgid stop "$NAME"
 i=0
 while [ "$(sed -n 3p "$DIR/bundle.info")" != 2 ]; do i=$((i+1)); [ "$i" -lt 12 ] || fail STOP_REGISTRATION_TIMEOUT; sleep 1; done
 for pid in $(owned); do kill -STOP "$pid" 2>/dev/null || :; done
 for pid in $(owned); do kill -TERM "$pid" 2>/dev/null || :; kill -CONT "$pid" 2>/dev/null || :; done
 sleep 2
 [ -z "$(owned)" ] || fail CHILD_STILL_RUNNING
 if [ "$held" = yes ] && [ ! -L /var/run/uuplugin.pid ] && [ /proc/$$/fd/9 -ef /var/run/uuplugin.pid ]; then
  busy=no
  for f in /proc/[0-9]*/fd/*; do
   [ "$f" != /proc/$$/fd/9 ] || continue
   if [ "$f" -ef /var/run/uuplugin.pid ]; then busy=yes; fi
  done
  [ "$busy" = yes ] || rm /var/run/uuplugin.pid
 fi
 if [ "$held" = yes ]; then exec 9<&-; fi
}
start_service() {
 [ ! -e "$BASE/uninstalled" ] || fail USE_RESTORE
 [ -f "$DATA/enabled" ] && [ ! -L "$DATA/enabled" ] || fail INSTALL_NOT_COMMITTED
 /bin/sidbg 74 osgid start "$NAME"
 i=0
 while :; do
  good=no
  for pid in $(owned); do [ "$(readlink /proc/"$pid"/exe)" != "$BASE/uuplugin" ] || good=yes; done
  [ "$good" = no ] || break
  i=$((i+1)); [ "$i" -lt 12 ] || fail START_NOT_CONFIRMED; sleep 1
 done
}
action=${1:-status}
if [ "$action" != status ]; then
 mkdir /var/lock/uu-skd847n-control.lock || fail OPERATION_IN_PROGRESS
 trap 'rmdir /var/lock/uu-skd847n-control.lock 2>/dev/null || :' 0
fi
case "$action" in
 status)
  echo VERSION=0.1.0-rc1
  echo "PERSISTENT_STATE=$(sed -n 3p "$DIR/bundle.info")"
  if [ -f "$BASE/reboot-verified" ] && [ ! -L "$BASE/reboot-verified" ] && [ "$(stat -c '%u:%a' "$BASE/reboot-verified")" = 0:600 ]; then
   expected="$(cat /proc/sys/kernel/random/boot_id):75c95271ab6139d11498f38a97061901e93ec6480c982975b841f3aa646ba445:2a0f7139fe4ee719a5e728e94273104b26e2f9ddfeeb82bd64d610b39b311d68"
   if [ "$(cat "$BASE/reboot-verified")" = "$expected" ]; then echo REBOOT_ACCEPTANCE=PASSED; else echo REBOOT_ACCEPTANCE=PREVIOUS_BOOT_ONLY; fi
  else echo REBOOT_ACCEPTANCE=PENDING; fi
  [ ! -f "$DATA/temp/status.properties" ] || sed '/^reboot_acceptance=/d' "$DATA/temp/status.properties"
  cloud=no;guard=no;main=no
  for pid in $(owned); do
   e=$(readlink /proc/"$pid"/exe);echo "PROCESS=$pid $e"
   grep -E '^(Uid|CapEff|CapAmb):' "/proc/$pid/status"
   case "$e" in */uuplugin) main=yes;; */xuplugin-guardian) guard=yes;; esac
   if netstat -antp 2>/dev/null | grep ':16000 ' | grep 'ESTABLISHED' | grep -Eq "[[:space:]]$pid/(uuplugin|xuplugin-guardian)$"; then cloud=yes; fi
  done
  echo "MAIN_RUNNING=$main";echo "GUARDIAN_RUNNING=$guard";echo "CLOUD_TCP_ESTABLISHED=$cloud"
  ;;
 start) start_service;;
 stop) stop_service;;
 uninstall) stop_service; : > "$BASE/uninstalled"; chmod 500 "$BASE/launch-uu"; echo UNINSTALLED_BINDING_PRESERVED;;
 restore) chmod 4555 "$BASE/launch-uu"; rm -f "$BASE/uninstalled"; start_service;;
 purge)
  stop_service
  # Revoke the fixed helper before removing the registration or its files.
  chmod 500 "$BASE/launch-uu"
  if [ -d /tmp/uu ] && [ ! -L /tmp/uu ]; then
   if [ -f /tmp/uu/activate_status ] && [ ! -L /tmp/uu/activate_status ]; then
    for identity in "$DATA/.sn" "$DATA/.uuplugin_uuid"; do
     if [ -f "$identity" ] && [ ! -L "$identity" ] && [ "$(cat "$identity")" = "$(cat /tmp/uu/activate_status)" ]; then
      rm /tmp/uu/activate_status; break
     fi
    done
   fi
   rmdir /tmp/uu 2>/dev/null || :
  fi
  /bin/sidbg 74 osgid uninstall "$NAME"
  i=0
  while [ -e "$DIR/bundle.info" ]; do i=$((i+1)); [ "$i" -lt 12 ] || fail UNINSTALL_REGISTRATION_TIMEOUT; sleep 1; done
  [ -z "$(owned)" ] || fail CHILD_REAPPEARED
  cd /
  rm -rf /usr/data/uu-wol-skd847n
  echo UNINSTALLED_FULL
  ;;
 *) fail UNKNOWN_ACTION;;
esac
