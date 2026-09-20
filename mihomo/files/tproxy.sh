#!/bin/sh
# mihomo tproxy route setup (managed by /etc/init.d/mihomo and luci-app-mihomo)
# Usage: tproxy.sh start|stop
# Adds/removes the fwmark policy route used by mihomo TPROXY mode.
# This is an editable file: changes take effect on the next mihomo restart.

MARK="0x100"
TABLE="256"

case "$1" in
	start)
		# 查重后再加: "ip rule add" 不指定 priority 时内核每次自动分配一个
		# 更低的新优先级, 内核因此把重复添加当成不同规则 (不报 File exists),
		# 反复 start 会积累出多条内容相同的规则。虽然只有第一条参与匹配,
		# 其余纯属残留, 但还是从源头上防一下。
		# 路由侧同理: "local default" 已存在时不再重复添加。
		ip rule show 2>/dev/null | grep -q "fwmark $MARK lookup $TABLE" || \
			ip rule add fwmark $MARK table $TABLE 2>/dev/null
		ip route show table $TABLE 2>/dev/null | grep -q "local default" || \
			ip route add local default dev lo table $TABLE 2>/dev/null
		;;
	stop)
		# stop 只删第一条匹配; 历史残留可能有多条, 循环删到删不动为止。
		while ip rule del fwmark $MARK table $TABLE 2>/dev/null; do :; done
		ip route del local default dev lo table $TABLE 2>/dev/null
		;;
esac

exit 0
