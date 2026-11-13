#!/bin/bash
# 连乐2 v5 终版：网口指示灯 + 长按复位恢复出厂 + 无线审计脚本(audit-air / audit-hcx)
# 基于 v4（已实机验证结构：交换机 0-4、LED 14/15/16、复位 17、SUPPORTED_DEVICES、iperf3）
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

# ---------- 3. 设备定义 ----------
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
echo "==> 设备定义已写入"

# ---------- 4. DTS：LED 14/15/16 高有效 ----------
DTS="$SRC/target/linux/ath79/dts/qca9531_letv_lba-047-ch.dts"
[ -f "$DTS" ] || { echo "!! 找不到 DTS"; exit 1; }
python3 - "$DTS" << 'PY'
import subprocess,sys
p=sys.argv[1]; s=open(p).read()
s=s.replace('<&gpio 13 GPIO_ACTIVE_LOW>','<&gpio 14 GPIO_ACTIVE_HIGH>')
s=s.replace('<&gpio 4 GPIO_ACTIVE_LOW>','<&gpio 15 GPIO_ACTIVE_HIGH>')
s=s.replace('<&gpio 11 GPIO_ACTIVE_LOW>','<&gpio 16 GPIO_ACTIVE_HIGH>')
s=s.replace('label = "blue:status"','label = "green:signal1"')
s=s.replace('label = "green:status"','label = "green:signal2"')
s=s.replace('label = "red:status"','label = "green:signal3"')
open(p,'w').write(s)
print(subprocess.run(['grep','-n','gpios',p],capture_output=True,text=True).stdout)
PY
echo "==> DTS 已改"

# ---------- 5. 网络（两口都 LAN，中继形态） ----------
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

# ---------- 6. WiFi / 时区 ----------
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
cat > "$SRC/files/etc/uci-defaults/99-le2-tz" << 'EOF'
#!/bin/sh
uci -q set system.@system[0].timezone='CST-8' || true
uci -q set system.@system[0].zonename='Asia/Shanghai' || true
uci -q set system.@system[0].ntp='1' || true
uci -q commit system
[ -x /etc/init.d/nodogsplash ] && /etc/init.d/nodogsplash disable 2>/dev/null
exit 0
EOF
chmod +x "$SRC/files/etc/uci-defaults/99-le2-wifi" "$SRC/files/etc/uci-defaults/99-le2-tz"

# ---------- 7. 复位键：短按重启 / 长按 5 秒恢复出厂 ----------
mkdir -p "$SRC/files/etc/rc.button"
cat > "$SRC/files/etc/rc.button/reset" << 'EOF'
#!/bin/sh
# 短按 -> 重启；按住 >=5 秒 -> 恢复出厂(firstboot)
FLAG=/tmp/le2-reset-hold
case "$ACTION" in
press|pressed)
	rm -f "$FLAG"
	echo pressed > "$FLAG"
	( sleep 5; [ -f "$FLAG" ] && echo hold > "$FLAG" ) &
	;;
timeout)
	echo hold > "$FLAG"
	logger -t le2-reset "长按 5 秒：恢复出厂"
	firstboot -y
	reboot
	;;
release|released)
	if [ "$(cat "$FLAG" 2>/dev/null)" = "hold" ]; then
		rm -f "$FLAG"
		logger -t le2-reset "长按：恢复出厂"
		firstboot -y
		reboot
	else
		rm -f "$FLAG"
		logger -t le2-reset "短按：重启"
		reboot
	fi
	;;
esac
EOF
chmod +x "$SRC/files/etc/rc.button/reset"

# ---------- 8. rc.local：网口指示灯 + 交换机兜底 + 诊断 ----------
cat > "$SRC/files/etc/rc.local" << 'EOF'
#!/bin/sh
for i in $(seq 1 20); do [ -d /sys/class/net/br-lan ] && break; sleep 1; done

swconfig dev switch0 set enable_vlan 1 2>/dev/null
swconfig dev switch0 vlan 1 set ports "0 1 2 3 4" 2>/dev/null

L=/sys/class/leds
if [ -d "$L/green:signal1" ]; then
	echo netdev > "$L/green:signal1/trigger" 2>/dev/null
	echo eth0 > "$L/green:signal1/device_name" 2>/dev/null
	echo 1 > "$L/green:signal1/link" 2>/dev/null
	echo 0 > "$L/green:signal1/tx" 2>/dev/null
	echo 0 > "$L/green:signal1/rx" 2>/dev/null
fi
if [ -d "$L/green:signal2" ]; then
	echo netdev > "$L/green:signal2/trigger" 2>/dev/null
	echo eth0 > "$L/green:signal2/device_name" 2>/dev/null
	echo 1 > "$L/green:signal2/tx" 2>/dev/null
	echo 1 > "$L/green:signal2/rx" 2>/dev/null
	echo 0 > "$L/green:signal2/link" 2>/dev/null
fi
if [ -d "$L/green:signal3" ]; then
	echo none > "$L/green:signal3/trigger" 2>/dev/null
	echo 0 > "$L/green:signal3/brightness" 2>/dev/null
fi

{ echo "=== swconfig ==="; swconfig dev switch0 show 2>&1;
  echo "=== brctl ==="; brctl show 2>&1;
  echo "=== speed ==="; cat /sys/class/net/eth0/speed /sys/class/net/eth1/speed 2>&1;
  echo "=== leds ==="; ls /sys/class/leds 2>&1;
  echo "=== network ==="; cat /etc/config/network 2>&1; } > /www/diag-net.txt 2>&1
exit 0
EOF
chmod +x "$SRC/files/etc/rc.local"


# ---------- 9. 自检（只验构建产物，不含任何审计脚本） ----------
echo "---- 设备定义 ----"; grep -A 16 'define Device/lelink_le2' "$GMK"
echo "---- DTS LED ----"; grep -n "gpios = <&gpio" "$DTS"
echo "---- 复位键 / rc.local ----"; ls -l "$SRC/files/etc/rc.button/" "$SRC/files/etc/" 2>/dev/null
for f in "$SRC/files/etc/rc.button/reset" "$SRC/files/etc/rc.local"; do
	if sh -n "$f"; then echo "ok $(basename $f)"; else echo "!! 语法错误 $(basename $f)"; fi
done
echo "---- 固件内不应有审计脚本 ----"
ls "$SRC/files/usr/bin/" 2>/dev/null || echo "（usr/bin 为空，正确）"
echo "==> 完成"
