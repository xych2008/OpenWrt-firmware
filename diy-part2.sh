#!/bin/bash
# diy-part2.sh：写入开机脚本（wlan0并入LAN桥、清空NAT）+ 改后台IP
mkdir -p files/etc
cat > files/etc/rc.local << 'EOF'
#!/bin/sh
# 开机延时后执行：无线wlan0并入LAN桥、清空NAT（二层透明）
sleep 8
brctl addif br-lan wlan0 2>/dev/null
iptables -F
iptables -t nat -F
exit 0
EOF

# 修改默认后台IP 192.168.2.1，避开主路由192.168.1.1
sed -i 's/192.168.1.1/192.168.2.1/g' package/base-files/files/bin/config_generate
