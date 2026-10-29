#!/bin/sh
set -eu
BASE=/opt/uu-wol-g7615
SERVICE=/etc/init.d/uu-wol-g7615
LINK=/etc/rc.d/S99uu-wol-g7615
KLINK=/etc/rc.d/K10uu-wol-g7615
fail() { echo "$1" >&2; exit 1; }
safe_path() {
 path=$1
 while [ "$path" != / ]; do
  [ ! -L "$path" ] || fail "SYMLINK:$path"
  path=${path%/*}; [ -n "$path" ] || path=/
 done
}
owned() {
 for entry in /proc/[0-9]*/exe; do
  exe=$(readlink "$entry" 2>/dev/null) || continue
  case "$exe" in "$BASE/uuplugin"|"$BASE/xuplugin-guardian")
   pid=${entry#/proc/}; pid=${pid%/exe}
   # Prevent selecting a different root with the same relative filename.
   [ "/proc/$pid/root$BASE/managed-v1" -ef "$BASE/managed-v1" ] || continue
   echo "$pid"
  ;; esac
 done
}
uu_running() {
 for pid in $(owned); do
  [ "$(readlink /proc/"$pid"/exe 2>/dev/null)" = "$BASE/uuplugin" ] && return 0
 done
 return 1
}
check_links() {
 for link in "$LINK" "$KLINK"; do
  if [ -e "$link" ] || [ -L "$link" ]; then
   [ -L "$link" ] && [ "$(readlink "$link")" = ../init.d/uu-wol-g7615 ] || fail BOOT_LINK_CHANGED
  fi
 done
}
stop_owned() {
 pid_identity=
 if [ -f /var/run/uuplugin.pid ] && [ ! -L /var/run/uuplugin.pid ]; then
  for pid in $(owned); do
   for fd in /proc/"$pid"/fd/*; do
    if [ "$fd" -ef /var/run/uuplugin.pid ]; then
     pid_identity=$(stat -c '%d:%i' /var/run/uuplugin.pid)
    fi
   done
  done
 fi
 /bin/sh /etc/rc.common "$SERVICE" stop || return 1
 # The guardian may outlive the supervised child. Select only our own executables.
 for pid in $(owned); do kill -STOP "$pid" 2>/dev/null || :; done
 for pid in $(owned); do kill -TERM "$pid" 2>/dev/null || :; kill -CONT "$pid" 2>/dev/null || :; done
 sleep 3
 [ -z "$(owned)" ] || fail STOP_INCOMPLETE
 if [ -n "$pid_identity" ] && [ ! -L /var/run/uuplugin.pid ] && [ -f /var/run/uuplugin.pid ] && [ "$(stat -c '%d:%i' /var/run/uuplugin.pid)" = "$pid_identity" ]; then
  in_use=no
  for fd in /proc/[0-9]*/fd/*; do
   if [ "$fd" -ef /var/run/uuplugin.pid ]; then in_use=yes; fi
  done
  [ "$in_use" = yes ] || rm /var/run/uuplugin.pid
 fi
}
start_owned() {
 [ ! -e "$BASE/uninstalled" ] || fail USE_RESTORE
 if [ -n "$(owned)" ]; then
  uu_running || fail ORPHAN_GUARDIAN
  echo ALREADY_RUNNING; return
 fi
 # UU uses global runtime paths; do not remove or take over another installation.
 for entry in /proc/[0-9]*/exe; do
  exe=$(readlink "$entry" 2>/dev/null) || continue
  case "$exe" in */uuplugin|*/xuplugin-guardian) fail OTHER_UU_RUNNING;; esac
 done
 /bin/sh /etc/rc.common "$SERVICE" start || return 1
 sleep 5
 uu_running || { stop_owned || :; fail START_FAILED_CHECK_LOGREAD; }
}
safe_path "$BASE"
safe_path "$SERVICE"
safe_path /etc/rc.d
[ -f "$BASE/managed-v1" ] && [ ! -L "$BASE/managed-v1" ] || fail NOT_MANAGED
cd "$BASE"
for f in control.sh service.sh run.sh payload.sha256 uuplugin xuplugin-guardian uu.conf; do
 [ -f "$f" ] && [ ! -L "$f" ] || fail "INVALID_FILE:$f"
done
sha256sum -c payload.sha256 >/dev/null || fail PAYLOAD_CHANGED
check_links
action=${1:-status}
if [ "$action" != status ]; then
 mkdir /tmp/uu-wol-g7615-control.lock || fail OPERATION_IN_PROGRESS
 trap 'rmdir /tmp/uu-wol-g7615-control.lock 2>/dev/null || :' 0
fi
if [ "$action" != register ]; then cmp -s service.sh "$SERVICE" || fail SERVICE_CHANGED; fi
case "$action" in
 register)
  [ ! -e "$SERVICE" ] && [ ! -L "$SERVICE" ] || fail SERVICE_EXISTS
  [ ! -e "$LINK" ] && [ ! -L "$LINK" ] && [ ! -e "$KLINK" ] && [ ! -L "$KLINK" ] || fail BOOT_LINK_EXISTS
  cp service.sh "$SERVICE" && chmod 755 "$SERVICE"
  ;;
 start) start_owned ;;
 stop) stop_owned ;;
 enable)
  [ ! -e uninstalled ] || fail USE_RESTORE
  /bin/sh /etc/rc.common "$SERVICE" enable
  check_links
  [ -L "$LINK" ] && [ -L "$KLINK" ] || fail ENABLE_FAILED
  ;;
 disable) /bin/sh /etc/rc.common "$SERVICE" disable ;;
 restore) rm -f uninstalled; start_owned ;;
 uninstall|purge)
  /bin/sh /etc/rc.common "$SERVICE" disable
  stop_owned
  : > uninstalled
  if [ "$action" = purge ]; then
   # Remove activation status only when it matches this installation's binding.
   if [ -d /tmp/uu ] && [ ! -L /tmp/uu ] && [ -f /tmp/uu/activate_status ] && [ ! -L /tmp/uu/activate_status ]; then
    for identity in "$BASE/.sn" "$BASE/.uuplugin_uuid"; do
     if [ -f "$identity" ] && [ ! -L "$identity" ] && cmp -s "$identity" /tmp/uu/activate_status; then
      rm /tmp/uu/activate_status
      rmdir /tmp/uu 2>/dev/null || :
      break
     fi
    done
   fi
   # Exact managed directory only; never touch CU framework or app siblings.
   rm "$SERVICE"
   cd /
   rm -rf /opt/uu-wol-g7615
  fi
  ;;
 status)
  echo VERSION=0.1.0-rc1
  if [ -f uninstalled ]; then echo state=UNINSTALLED; elif uu_running; then echo state=RUNNING; elif [ -n "$(owned)" ]; then echo state=FAILED_ORPHAN_GUARDIAN; else echo state=STOPPED; fi
  if [ -L "$LINK" ] && [ -L "$KLINK" ]; then echo AUTOSTART=ENABLED; else echo AUTOSTART=DISABLED; fi
  for pid in $(owned); do echo "PROCESS=$pid $(readlink /proc/$pid/exe)"; done
  echo CLOUD=UNVERIFIED
  echo LOG=procd-logread
  ;;
 *) fail UNKNOWN_ACTION ;;
esac
