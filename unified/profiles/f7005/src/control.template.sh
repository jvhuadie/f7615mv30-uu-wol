#!/bin/sh
set -eu
BASE=/usr/plugin/uu-wol-f7005
NAME=local.ont.uuwol.f7005
[ "$(id -u)" = 0 ] && [ "$(uname -n)" = F7005MV3 ] || exit 1
echo '453c47535b274071a5ae83d533d825e5072c8b562857e51eeefa8826953180ed  /bin/cspd' | sha256sum -c - >/dev/null || exit 1
echo '@JARHASH@  /usr/plugin/uu-wol-f7005/service.jar' | sha256sum -c - >/dev/null || exit 1
count=0
for info in /usr/plugin/bundlecache/bundle*/bundle.info; do
 [ -f "$info" ] || continue
 if [ "$(sed -n 2p "$info")" = "file:$BASE/service.jar" ]; then count=$((count+1)); DIR=${info%/bundle.info}; fi
done
[ "$count" = 1 ] || { echo REGISTRATION_NOT_UNIQUE; exit 1; }
echo "@JARHASH@  $DIR/version0.0/bundle.jar" | sha256sum -c - >/dev/null || exit 1
DATA=$DIR/data
stop_service() {
 sendcmd 74 osgidcomm stop "$NAME"
 for n in 1 2 3 4 5; do [ "$(sed -n 3p "$DIR/bundle.info")" = 2 ] && break; sleep 1; done
 [ "$(sed -n 3p "$DIR/bundle.info")" = 2 ] || exit 1
 for proc in /proc/[0-9]*; do
  exe=$(readlink "$proc/exe" 2>/dev/null) || continue
  case "$exe" in "$DATA/uuplugin"|"$DATA/xuplugin-guardian")
   grep -q '^Uid:[[:space:]]*58327[[:space:]]' "$proc/status" || exit 1
   kill "${proc##*/}" 2>/dev/null || true;;
  esac
 done
 sleep 1
 for proc in /proc/[0-9]*; do
  exe=$(readlink "$proc/exe" 2>/dev/null) || continue
  case "$exe" in "$DATA/uuplugin"|"$DATA/xuplugin-guardian"|"$DATA/pid-prepare") echo CHILD_STILL_RUNNING; exit 1;; esac
 done
}
case "${1:-status}" in
 status)
  echo VERSION=0.1.0-rc1; echo REBOOT_ACCEPTANCE=PENDING; echo "DATA=$DATA"
  echo "PERSISTENT_STATE=$(sed -n 3p "$DIR/bundle.info")"
  [ ! -f "$DATA/temp/status.properties" ] || cat "$DATA/temp/status.properties"
  for proc in /proc/[0-9]*; do
   exe=$(readlink "$proc/exe" 2>/dev/null) || continue
   case "$exe" in "$DATA/uuplugin"|"$DATA/xuplugin-guardian") echo "PROCESS=${proc##*/} $exe"; grep -E 'Uid:|CapEff:' "$proc/status";; esac
  done
  netstat -anp | grep -E 'uuplugin|guardian' || true
  ;;
 stop) stop_service; echo STOPPED_AUTOSTART_DISABLED;;
 start)
  [ -f "$DATA/enabled" ] || { echo INSTALL_NOT_COMMITTED; exit 1; }
  for role in uu pid; do
   flags=$("$BASE/$role-flags-get" | busybox hexdump -v -e '1/4 "%u"')
   [ -n "$flags" ] && [ $((flags & 16)) -ne 0 ] || { echo FILE_PROTECTION_MISSING; exit 1; }
  done
  sendcmd 74 osgidcomm run "$NAME"; echo START_REQUESTED_AUTOSTART_ENABLED;;
 uninstall)
  stop_service
  for role in uu pid; do
   "$BASE/$role-flags-unlock" >/dev/null || { echo FILE_UNLOCK_FAILED; exit 1; }
   set +e; "$BASE/$role-get" >/dev/null; rc=$?; set -e
   case "$rc" in 0) "$BASE/$role-remove" || exit 1;; 61) :;; *) echo CAPABILITY_READ_FAILED; exit 1;; esac
   set +e; "$BASE/$role-get" >/dev/null; rc=$?; set -e
   [ "$rc" = 61 ] || { echo CAPABILITY_REVOKE_UNCONFIRMED; exit 1; }
  done
  if [ -e /var/run/uuplugin.pid ] || [ -L /var/run/uuplugin.pid ]; then
   [ ! -L /var/run/uuplugin.pid ] && [ -f "$DATA/temp/pid.inode" ] || { echo PID_OWNERSHIP_UNCONFIRMED; exit 1; }
   set -- $(ls -lni /var/run/uuplugin.pid)
   [ "$1" = "$(cat "$DATA/temp/pid.inode")" ] && [ "$2" = -rw------- ] && [ "$4" = 58327 ] && [ "$5" = 0 ] || exit 1
   for fd in /proc/[0-9]*/fd/*; do target=$(readlink "$fd" 2>/dev/null) || continue; [ "$target" != /var/run/uuplugin.pid ] || { echo PID_IN_USE; exit 1; }; done
   rm /var/run/uuplugin.pid
  fi
  if [ -f /tmp/uu/activate_status ]; then
   match=no
   for identity in "$DATA/.sn" "$DATA/.uuplugin_uuid"; do
    if [ -f "$identity" ] && [ "$(cat /tmp/uu/activate_status)" = "$(cat "$identity")" ]; then match=yes; fi
   done
   if [ "$match" = yes ]; then rm /tmp/uu/activate_status; rmdir /tmp/uu 2>/dev/null || true; else echo FOREIGN_ACTIVATION_FILE_PRESERVED; fi
  elif [ -d /tmp/uu ]; then rmdir /tmp/uu 2>/dev/null || true; fi
  sendcmd 74 osgidcomm uninstall "$NAME"
  for n in 1 2 3 4 5 6 7 8 9 10; do [ ! -e "$DIR/bundle.info" ] && break; sleep 1; done
  [ ! -e "$DIR/bundle.info" ] || exit 1
  echo UNINSTALLED_REVOKED
  ;;
 *) echo 'usage: status | start | stop | uninstall'; exit 2;;
esac
