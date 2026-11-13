#!/bin/bash
# diy-part2.sh：写入开机脚本（无线挂 LAN、二层不做 NAT）+ 改后台IP
mkdir -p files/etc
cat > files/etc/rc.local << 'EOF'
#!/bin/sh
# 23.05 走 firewall4/nftables，镜像里没有 iptables 命令，原来两行 iptables 一律 command not found
# 无线归属由 /etc/config/wireless 的 option network 'lan' 决定，不需要 brctl 手工桥接
sleep 5
[ -n "$(uci -q get wireless.default_radio0)" ] && uci -q set wireless.default_radio0.network='lan'
uci -q commit wireless 2>/dev/null
wifi up 2>/dev/null
# 二层透明：LAN 区不做 NAT（下载默认是 1）
uci -q set firewall.@zone[0].masq='0' 2>/dev/null
uci -q commit firewall 2>/dev/null
/etc/init.d/firewall reload 2>/dev/null
exit 0
EOF

# 修改默认后台IP 192.168.2.1，避开主路由192.168.1.1（已在镜像里确认生效）
sed -i 's/192.168.1.1/192.168.2.1/g' package/base-files/files/bin/config_generate
# 注意：luci-network / luci-system 不是真实包名，真实的是 luci-mod-network / luci-mod-system
echo "CONFIG_PACKAGE_luci-mod-network=y" >> .config
echo "CONFIG_PACKAGE_luci-mod-system=y" >> .config
echo "CONFIG_PACKAGE_aircrack-ng=y" >> .config
echo "CONFIG_PACKAGE_airmon-ng=y" >> .config
echo "CONFIG_PACKAGE_openssh-sftp-server=y" >> .config

