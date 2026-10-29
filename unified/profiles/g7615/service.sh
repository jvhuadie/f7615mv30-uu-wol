#!/bin/sh /etc/rc.common
# Owned by zte-ont-uu-wol, G7615V2 candidate 0.1.0-rc1.
START=99
STOP=10
USE_PROCD=1
start_service() {
 [ -f /opt/uu-wol-g7615/managed-v1 ] || return 1
 [ ! -f /opt/uu-wol-g7615/uninstalled ] || return 1
 procd_open_instance main
 procd_set_param command /bin/sh /opt/uu-wol-g7615/run.sh
 # No automatic restart until guardian lifecycle is verified on hardware.
 procd_set_param stdout 1
 procd_set_param stderr 1
 procd_set_param term_timeout 5
 procd_close_instance
}
