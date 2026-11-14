#!/bin/bash
# 连乐2 v8 = v7 功能不变，但启动路径退回 v4 原文（rc.local/rc.button 与 v4 逐字一致）
# 实测结论：VLAN1 ports "0 1 2 3 4"、各口 pvid 1；LED 节点 green:signal1/2/3；
#           br-lan = eth0 + eth1 + phy0-ap0；IP 192.168.1.1；工具路径已核对
# 保持 v4 的“开机自愈”：sleep 5 + ip link set eth0/eth1 master br-lan + swconfig 兜底
set -e

WS="${GITHUB_WORKSPACE:-$(cd .. && pwd)}"
if [ -d "target/linux/ath79" ]; then
	SRC="$(pwd)"
else
	SRC="$WS/openwrt"
fi
[ -d "$SRC/target/linux/ath79" ] || { echo "!! 找不到源码树"; exit 1; }

# ---------- 1. 屏蔽旧 diy-part2.sh ----------
cat > "$WS/diy-part2.sh" << 'EOS'
#!/bin/bash
exit 0
EOS
chmod +x "$WS/diy-part2.sh"

# ---------- 2. .config ----------
CFG="$WS/.config"
add_cfg() { grep -q "^$1=y" "$CFG" 2>/dev/null || echo "$1=y" >> "$CFG"; }
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
add_cfg CONFIG_PACKAGE_reaver
add_cfg CONFIG_PACKAGE_pixiewps
add_cfg CONFIG_PACKAGE_tmux
add_cfg CONFIG_PACKAGE_nodogsplash
add_cfg CONFIG_PACKAGE_luci-app-commands
add_cfg CONFIG_PACKAGE_iperf3
sed -i '/CONFIG_PACKAGE_luci-network=y/d; /CONFIG_PACKAGE_luci-system=y/d' "$CFG" 2>/dev/null || true
echo "==> .config 已补包"

# ---------- 3. 设备定义：补 SUPPORTED_DEVICES ----------
GMK="$SRC/target/linux/ath79/image/generic.mk"
if grep -q "^define Device/lelink_le2$" "$GMK"; then
	sed -i '/^define Device\/lelink_le2$/,/^TARGET_DEVICES += lelink_le2$/d' "$GMK"
fi
cat >> "$GMK" << 'EOF'

# 连乐2：沿用上游乐视 LBA-047-CH 的 DTS 与 OKLI 引导方案
# 交换机端口：0=CPU(AR8228)，1/2 空，3/4 为两个物理网口
define Device/lelink_le2
  $(Device/loader-okli-uimage)
  SOC := qca9531
  DEVICE_VENDOR := Lelink
  DEVICE_MODEL := LE2
  DEVICE_DTS := qca9531_letv_lba-047-ch
  SUPPORTED_DEVICES := letv,lba-047-ch lelink,le2
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
echo "==> 设备定义已写入（含 SUPPORTED_DEVICES）"

# ---------- 4. 改 DTS：LED 用实测的 14/15/16，高电平有效 ----------
DTS="$SRC/target/linux/ath79/dts/qca9531_letv_lba-047-ch.dts"
[ -f "$DTS" ] || { echo "!! 找不到 DTS"; exit 1; }
python3 - "$DTS" << 'PY'
import re,sys
p=sys.argv[1]
s=open(p).read()
# LED0: 13 -> 14，高有效；LED1: 4 -> 15；LED2: 11 -> 16
s=s.replace('<&gpio 13 GPIO_ACTIVE_LOW>','<&gpio 14 GPIO_ACTIVE_HIGH>')
s=s.replace('<&gpio 4 GPIO_ACTIVE_LOW>','<&gpio 15 GPIO_ACTIVE_HIGH>')
s=s.replace('<&gpio 11 GPIO_ACTIVE_LOW>','<&gpio 16 GPIO_ACTIVE_HIGH>')
# 名字改成信号格
s=s.replace('label = "blue:status"','label = "green:signal1"')
s=s.replace('label = "green:status"','label = "green:signal2"')
s=s.replace('label = "red:status"','label = "green:signal3"')
open(p,'w').write(s)
# 校验
import subprocess
print(subprocess.run(['grep','-n','gpios',p],capture_output=True,text=True).stdout)
PY
echo "==> DTS 已改"

# ---------- 5. 网络：交换机全口 0 1 2 3 4（3/4 才是物理网口） ----------
mkdir -p "$SRC/files/etc/uci-defaults"
cat > "$SRC/files/etc/uci-defaults/99-le2-net" << 'EOF'
#!/bin/sh
u() { uci -q "$@"; }
u delete network.wan
u delete network.wan6
while u delete network.@switch_vlan[0]; do :; done
while u delete network.@switch[0]; do :; done
for i in 9 8 7 6 5 4 3 2 1 0; do
	[ "$(u get network.@device[$i].name)" = "br-lan" ] && u delete network.@device[$i]
done
u add network device
u set network.@device[-1].name='br-lan'
u set network.@device[-1].type='bridge'
u add_list network.@device[-1].ports='eth0'
u add_list network.@device[-1].ports='eth1'
u add network switch
u set network.@switch[-1].name='switch0'
u set network.@switch[-1].reset='1'
u set network.@switch[-1].enable_vlan='1'
u add network switch_vlan
u set network.@switch_vlan[-1].device='switch0'
u set network.@switch_vlan[-1].vlan='1'
u set network.@switch_vlan[-1].ports='0 1 2 3 4'
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

# ---------- 6. WiFi / 时区 / nodogsplash ----------
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

cat > "$SRC/files/etc/uci-defaults/99-le2-tz" << 'EOF'
#!/bin/sh
uci -q set system.@system[0].timezone='CST-8' || true
uci -q set system.@system[0].zonename='Asia/Shanghai' || true
uci -q set system.@system[0].ntp='1' || true
uci -q set system.ntp='timeserver' || true
uci -q commit system
[ -x /etc/init.d/nodogsplash ] && /etc/init.d/nodogsplash disable 2>/dev/null
exit 0
EOF
chmod +x "$SRC/files/etc/uci-defaults/99-le2-tz"

# ---------- 7. GPIO 扫描工具 ----------
mkdir -p "$SRC/files/usr/bin"
cat > "$SRC/files/usr/bin/led-scan" << 'EOF'
#!/bin/sh
G=/sys/class/gpio
[ -d $G ] || { echo "no $G"; exit 1; }
echo "扫描 GPIO 0-22，每个亮 2 秒，记录亮灯编号（14/15/16 是信号灯，已被占用会跳过）"
for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22; do
	echo $i > $G/export 2>/dev/null || continue
	echo out > $G/gpio$i/direction 2>/dev/null || { echo $i > $G/unexport; continue; }
	echo 1 > $G/gpio$i/value 2>/dev/null
	echo "===== GPIO $i ====="
	sleep 2
	echo 0 > $G/gpio$i/value 2>/dev/null
	echo $i > $G/unexport 2>/dev/null
done
EOF
chmod +x "$SRC/files/usr/bin/led-scan"

cat > "$SRC/files/usr/bin/btn-scan" << 'EOF'
#!/bin/sh
# 简化版：先打印全部输入电平，再提示按键，第二次打印，靠肉眼比对
G=/sys/class/gpio
L="0 1 2 3 4 5 6 7 8 9 10 11 12 13 17 18 19 20 21 22"
scan() {
	for i in $L; do
		echo $i > $G/export 2>/dev/null
		echo in > $G/gpio$i/direction 2>/dev/null || continue
		echo "G$i=$(cat $G/gpio$i/value 2>/dev/null)"
	done
}
echo "----- 未按下 -----"
scan
echo "----- 现在按住复位键 10 秒 -----"
sleep 10
echo "----- 按住中 -----"
scan
echo "对比两段，值变了的那行就是复位键"
EOF
chmod +x "$SRC/files/usr/bin/btn-scan"

# ---------- 7.5 复位键 = OpenWrt 官方原版（v4 实测可用，不自行改写） ----------
mkdir -p "$SRC/files/etc/rc.button"
cat > "$SRC/files/etc/rc.button/reset" << 'RBEOF'
#!/bin/sh

. /lib/functions.sh

OVERLAY="$( grep ' /overlay ' /proc/mounts )"

case "$ACTION" in
pressed)
	[ -z "$OVERLAY" ] && return 0

	return 5
;;
timeout)
	. /etc/diag.sh
	set_state failsafe
;;
released)
	if [ "$SEEN" -lt 1 ]
	then
		echo "REBOOT" > /dev/console
		sync
		reboot
	elif [ "$SEEN" -ge 5 -a -n "$OVERLAY" ]
	then
		echo "FACTORY RESET" > /dev/console
		jffs2reset -y && reboot &
	fi
;;
esac

return 0
RBEOF
chmod +x "$SRC/files/etc/rc.button/reset"

# ---------- 8. rc.local = v4 原文 + LED 延迟后台点灯 ----------
cat > "$SRC/files/etc/rc.local" << 'EOF'
#!/bin/sh
sleep 5
for i in eth0 eth1; do
	ip link set $i master br-lan 2>/dev/null || true
done
swconfig dev switch0 set enable_vlan 1 2>/dev/null
swconfig dev switch0 vlan 1 set ports "0 1 2 3 4" 2>/dev/null
{ echo "=== swconfig ==="; swconfig dev switch0 show 2>&1;
  echo "=== brctl ==="; brctl show 2>&1;
  echo "=== speed ==="; cat /sys/class/net/eth0/speed /sys/class/net/eth1/speed 2>&1;
  echo "=== network ==="; cat /etc/config/network 2>&1; } > /www/diag-net.txt 2>&1

# LED 点灯放到开机 20 秒后的后台子进程里，绝不影响启动
(
	sleep 20
	L=/sys/class/leds
	if [ -e "$L/green:signal1" ]; then
		echo netdev > "$L/green:signal1/trigger" 2>/dev/null || true
		echo eth0 > "$L/green:signal1/device_name" 2>/dev/null || true
		echo 1 > "$L/green:signal1/link" 2>/dev/null || true
		echo 0 > "$L/green:signal1/tx" 2>/dev/null || true
		echo 0 > "$L/green:signal1/rx" 2>/dev/null || true
	fi
	if [ -e "$L/green:signal2" ]; then
		echo netdev > "$L/green:signal2/trigger" 2>/dev/null || true
		echo eth0 > "$L/green:signal2/device_name" 2>/dev/null || true
		echo 1 > "$L/green:signal2/tx" 2>/dev/null || true
		echo 1 > "$L/green:signal2/rx" 2>/dev/null || true
		echo 0 > "$L/green:signal2/link" 2>/dev/null || true
	fi
	if [ -e "$L/green:signal3" ]; then
		echo none > "$L/green:signal3/trigger" 2>/dev/null || true
		echo 0 > "$L/green:signal3/brightness" 2>/dev/null || true
	fi
) >/dev/null 2>&1 &
exit 0
EOF
chmod +x "$SRC/files/etc/rc.local"

# ---------- 9. 自检 ----------
echo "---- 设备定义 ----"; grep -A 16 'define Device/lelink_le2' "$GMK"
echo "---- DTS LED ----"; grep -n -B1 "GPIO_ACTIVE_HIGH\|gpios = <&gpio 17" "$DTS"
echo "---- 包 ----"; grep -E 'PACKAGE_iperf3|PACKAGE_hcxdumptool|PACKAGE_reaver|PACKAGE_nodogsplash|PACKAGE_luci-app-commands' "$CFG"
echo "---- 启动脚本语法 ----"
for f in "$SRC/files/etc/rc.local" "$SRC/files/etc/rc.button/reset" "$SRC/files/etc/uci-defaults/99-le2-net"; do
	if sh -n "$f"; then echo "ok $(basename $f)"; else echo "!! 语法错误 $(basename $f)"; fi
done
echo "==> 完成"
