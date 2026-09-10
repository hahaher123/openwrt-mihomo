#!/bin/sh
# mihomo tproxy route setup (managed by /etc/init.d/mihomo and luci-app-mihomo)
# Usage: tproxy.sh start|stop
# Adds/removes the fwmark policy route used by mihomo TPROXY mode.
# This is an editable file: changes take effect on the next mihomo restart.

MARK="0x100"
TABLE="256"

case "$1" in
	start)
		ip rule add fwmark $MARK table $TABLE 2>/dev/null
		ip route add local default dev lo table $TABLE 2>/dev/null
		;;
	stop)
		ip rule del fwmark $MARK table $TABLE 2>/dev/null
		ip route del local default dev lo table $TABLE 2>/dev/null
		;;
esac

exit 0
