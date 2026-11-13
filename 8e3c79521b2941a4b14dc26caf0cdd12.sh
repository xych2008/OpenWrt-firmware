#!/bin/bash
# 连乐2 / 乐视 LBA-047-CH  —— v2：全口并入 br-lan（有线可用）+ LED/复位键扫描工具
# 布局不变：0x50000 = OKLI 内核+文件系统；0xE80000 = 64K loader（官方原厂方式）
set -e

WS="${GITHUB_WORKSPACE:-$(cd .. && pwd)}"
if [ -d "target/linux/ath79" ]; then
	SRC="$(pwd)"
else
	SRC="$WS/openwrt"
fi
[ -d "$SRC/target/linux/ath79" ] || { echo "!! 找不到 immortalwrt 源码树，退出"; exit 1; }
echo "==> 仓库根: $WS"
echo "==> 源码树: $SRC"

# ---------- 0b. 确保 routing feed 存在（nodogsplash 在 routing 里） ----------
for f in "$SRC/feeds.conf" "$SRC/feeds.conf.default"; do
	[ -f "$f" ] || continue
	grep -q "routing" "$f" 2>/dev/null || \
		echo "src-git routing https://github.com/openwrt/routing.git^23.05" >> "$f"
	echo "==> $f 已确认 routing feed"
done

# ---------- 1. 屏蔽旧的 diy-part2.sh ----------
cat > "$WS/diy-part2.sh" << 'EOS'
#!/bin/bash
exit 0
EOS
chmod +x "$WS/diy-part2.sh"

# ---------- 2. .config 补必需包 ----------
CFG="$WS/.config"
add_cfg() {
	grep -q "^$1=y" "$CFG" 2>/dev/null || echo "$1=y" >> "$CFG"
}
add_cfg CONFIG_PACKAGE_luci
add_cfg CONFIG_PACKAGE_luci-base
add_cfg CONFIG_PACKAGE_luci-i18n-base-zh-cn
add_cfg CONFIG_PACKAGE_wpad-basic-mbedtls
add_cfg CONFIG_PACKAGE_kmod-ath9k
add_cfg CONFIG_PACKAGE_iw
add_cfg CONFIG_PACKAGE_bridge-utils
add_cfg CONFIG_PACKAGE_aircrack-ng
add_cfg CONFIG_PACKAGE_airmon-ng
add_cfg CONFIG_PACKAGE_hcxdumptool
add_cfg CONFIG_PACKAGE_hcxtools
add_cfg CONFIG_PACKAGE_tmux
add_cfg CONFIG_PACKAGE_reaver
add_cfg CONFIG_PACKAGE_pixiewps
add_cfg CONFIG_PACKAGE_nodogsplash
add_cfg CONFIG_PACKAGE_luci-app-commands
sed -i '/CONFIG_PACKAGE_luci-network=y/d; /CONFIG_PACKAGE_luci-system=y/d' "$CFG" 2>/dev/null || true
echo "==> .config 已补包"

# ---------- 3. 设备定义（保持原样，OKLI 方案） ----------
GMK="$SRC/target/linux/ath79/image/generic.mk"
if grep -q "^define Device/lelink_le2$" "$GMK"; then
	sed -i '/^define Device\/lelink_le2$/,/^TARGET_DEVICES += lelink_le2$/d' "$GMK"
fi
cat >> "$GMK" << 'EOF'

# 连乐2：沿用上游乐视 LBA-047-CH 的 DTS 与 OKLI 引导方案
define Device/lelink_le2
  $(Device/loader-okli-uimage)
  SOC := qca9531
  DEVICE_VENDOR := Lelink
  DEVICE_MODEL := LE2
  DEVICE_DTS := qca9531_letv_lba-047-ch
  DEVICE_PACKAGES := -uboot-envtools
  FACTORY_SIZE := 14528k
  IMAGE_SIZE := 15936k
  LOADER_FLASH_OFFS := 0x50000
  KERNEL := kernel-bin | append-dtb | lzma | uImage lzma -M 0x4f4b4c49
  IMAGES := sysupgrade.bin factory.bin kernel.bin rootfs.bin
  IMAGE/kernel.bin := append-loader-okli-uimage $(1) | pad-to 64k
  IMAGE/rootfs.bin := append-kernel | pad-to $$$$(BLOCKSIZE) | append-rootfs | pad-rootfs | check-size $$$$(FACTORY_SIZE)
  IMAGE/factory.bin := append-kernel | pad-to $$$$(BLOCKSIZE) | append-rootfs | pad-rootfs | pad-to 14876672 | append-loader-okli-uimage $(1)
endef
TARGET_DEVICES += lelink_le2
EOF
echo "==> OKLI 设备定义已写入"

# ---------- 4. 网络强制修正：所有网卡并入 br-lan，交换机单 VLAN 全 untagged ----------
mkdir -p "$SRC/files/etc/uci-defaults"
cat > "$SRC/files/etc/uci-defaults/99-le2-net" << 'EOF'
#!/bin/sh
# 连乐2 网口修正：上游 02_network 用的是不存在的端口 3/4
# 本板 switch0 只有 LAN1/LAN2 两个口 + CPU(eth1)。这里整体重建，全部并入 br-lan。
u() { uci -q "$@"; }

# 1) 去掉 wan / wan6（两个物理口都当 LAN 用）
u delete network.wan
u delete network.wan6

# 2) 清掉自动生成的 switch / switch_vlan（含错误的 3、4 号口）
while u delete network.@switch_vlan[0]; do :; done
while u delete network.@switch[0]; do :; done

# 3) 清掉已有名为 br-lan 的 device 段
for i in 9 8 7 6 5 4 3 2 1 0; do
	[ "$(u get network.@device[$i].name)" = "br-lan" ] && u delete network.@device[$i]
done

# 4) 建 br-lan：eth0 + eth1 全进桥，插哪个口都能进后台
u add network device
u set network.@device[-1].name='br-lan'
u set network.@device[-1].type='bridge'
u add_list network.@device[-1].ports='eth0'
u add_list network.@device[-1].ports='eth1'

# 5) 交换机：单 VLAN，CPU 口与两个物理口全部 untagged
u add network switch
u set network.@switch[-1].name='switch0'
u set network.@switch[-1].reset='1'
u set network.@switch[-1].enable_vlan='1'
u add network switch_vlan
u set network.@switch_vlan[-1].device='switch0'
u set network.@switch_vlan[-1].vlan='1'
u set network.@switch_vlan[-1].ports='0 1 2'

# 6) lan 接口
u set network.lan='interface'
u set network.lan.device='br-lan'
u set network.lan.proto='static'
u set network.lan.ipaddr='192.168.1.1'
u set network.lan.netmask='255.255.255.0'
u set network.lan.ip6assign='60'

u commit network
exit 0
EOF
chmod +x "$SRC/files/etc/uci-defaults/99-le2-net"

# ---------- 5. WiFi 默认开 ----------
cat > "$SRC/files/etc/uci-defaults/99-le2-wifi" << 'EOF'
#!/bin/sh
[ -f /etc/config/wireless ] || wifi config >/dev/null 2>&1
if [ -f /etc/config/wireless ]; then
	uci -q set wireless.radio0.disabled='0' || true
	uci -q set wireless.@wifi-iface[0].disabled='0' || true
	uci -q set wireless.@wifi-iface[0].ssid='OpenWrt' || true
	uci -q set wireless.@wifi-iface[0].encryption='none' || true
	uci -q set wireless.@wifi-iface[0].network='lan' || true
	uci -q commit wireless
fi
exit 0
EOF
chmod +x "$SRC/files/etc/uci-defaults/99-le2-wifi"

# ---------- 6. 时区 / NTP ----------
cat > "$SRC/files/etc/uci-defaults/99-le2-tz" << 'EOF'
#!/bin/sh
uci -q set system.@system[0].timezone='CST-8' || true
uci -q set system.@system[0].zonename='Asia/Shanghai' || true
uci -q set system.@system[0].ntp='1' || true
uci -q set system.ntp='timeserver' || true
uci -q commit system
exit 0
EOF
chmod +x "$SRC/files/etc/uci-defaults/99-le2-tz"

# ---------- 6b. nodogsplash 默认不启用（免得它抢了 br-lan 的上网） ----------
cat > "$SRC/files/etc/uci-defaults/99-le2-misc" << 'EOF'
#!/bin/sh
[ -x /etc/init.d/nodogsplash ] && /etc/init.d/nodogsplash disable 2>/dev/null
exit 0
EOF
chmod +x "$SRC/files/etc/uci-defaults/99-le2-misc"

# ---------- 7. GPIO 扫描工具 ----------
mkdir -p "$SRC/files/usr/bin"
cat > "$SRC/files/usr/bin/led-scan" << 'EOF'
#!/bin/sh
G=/sys/class/gpio
[ -d $G ] || { echo "没有 $G，内核未开 GPIO sysfs"; exit 1; }
echo "开始扫描 GPIO 0-31，每个亮 2 秒。看面板哪个灯亮 = 那个编号"
for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31; do
	echo $i > $G/export 2>/dev/null || continue
	if ! echo out > $G/gpio$i/direction 2>/dev/null; then
		echo $i > $G/unexport 2>/dev/null
		continue
	fi
	echo 1 > $G/gpio$i/value 2>/dev/null
	echo "===== GPIO $i ====="
	sleep 2
	echo 0 > $G/gpio$i/value 2>/dev/null
	sleep 1
	echo $i > $G/unexport 2>/dev/null
done
echo "扫描结束。把亮灯时对应的编号告诉我"
EOF
chmod +x "$SRC/files/usr/bin/led-scan"

cat > "$SRC/files/usr/bin/btn-scan" << 'EOF'
#!/bin/sh
G=/sys/class/gpio
[ -d $G ] || { echo "没有 $G"; exit 1; }
snap() {
	for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31; do
		echo $i > $G/export 2>/dev/null
		if echo in > $G/gpio$i/direction 2>/dev/null; then
			echo "$i=$(cat $G/gpio$i/value 2>/dev/null)"
		else
			echo $i > $G/unexport 2>/dev/null
		fi
	done
}
echo "第一步：不要按键，采集基准..."
snap > /tmp/gpio-a.txt
echo "基准已采集，可用 GPIO $(grep -c '=' /tmp/gpio-a.txt) 个"
echo ""
echo "第二步：现在按住复位键别松手，10 秒后自动对比 —— 按！"
sleep 10
snap > /tmp/gpio-b.txt
echo "有变化的（GPIO : 基准 -> 按住时）："
awk -F= 'NR==FNR{a[$1]=$2;next} ($1 in a) && a[$1]!=$2 {print "  GPIO " $1 " : " a[$1] " -> " $2}' /tmp/gpio-a.txt /tmp/gpio-b.txt
echo ""
echo "若无输出，说明复位键不在这批 GPIO；把 /tmp/gpio-a.txt、/tmp/gpio-b.txt 内容发我"
EOF
chmod +x "$SRC/files/usr/bin/btn-scan"

# ---------- 8. rc.local：兜底桥接 + 诊断文件放到网页 ----------
cat > "$SRC/files/etc/rc.local" << 'EOF'
#!/bin/sh
sleep 8
for i in eth0 eth1; do
	ip link set $i master br-lan 2>/dev/null || brctl addif br-lan $i 2>/dev/null
done
swconfig dev switch0 set enable_vlan 1 2>/dev/null
swconfig dev switch0 vlan 1 set ports "0 1 2" 2>/dev/null

# 浏览器直接开 http://192.168.1.1/diag-net.txt 就能看到诊断，不用 SSH
{ echo "=== swconfig ==="; swconfig dev switch0 show 2>&1;
  echo "=== ip link ==="; ip -br link 2>&1;
  echo "=== ip addr ==="; ip -br addr 2>&1;
  echo "=== brctl ==="; brctl show 2>&1;
  echo "=== network ==="; cat /etc/config/network 2>&1; } > /www/diag-net.txt 2>&1

exit 0
EOF
chmod +x "$SRC/files/etc/rc.local"

# ---------- 9. 自检 ----------
echo "---- .config 关键项 ----"
grep -E 'DEVICE_lelink_le2|PACKAGE_wpad|PACKAGE_aircrack|PACKAGE_kmod-ath9k|PACKAGE_luci-app-commands' "$CFG" || true
echo "---- 设备定义 ----"
grep -A 14 'define Device/lelink_le2' "$GMK"
echo "---- 新脚本 ----"
ls -l "$SRC/files/etc/uci-defaults/" && ls -l "$SRC/files/usr/bin/" && ls -l "$SRC/files/etc/rc.local"
echo "==> 完成"
