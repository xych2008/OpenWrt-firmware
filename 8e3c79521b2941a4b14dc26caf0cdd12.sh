#!/bin/bash
# 百米 HD51 v5：修 2.4G 不广播（wmac 校准数据改正）+ 打开 SDHCI + 无线配置烘进镜像
# 百米 HD51 自检版：MT7620A + 128MB + 16MB(MX25L12835E) + 百兆 5 口 + USB + PCIe/5G 探测
# 复位键 GPIO13（原厂 /etc/init.d/boot:61 `btnd reset 13`）
# 依据原厂 16MB dump 实测分区：u-boot 0x0/0x30000, env 0x30000/0x10000,
# factory 0x40000/0x40000(0x200 校准), firmware 0x80000/0x6F0000, data 0x770000/0x890000
set -e

WS="${GITHUB_WORKSPACE:-$(cd .. && pwd)}"
if [ -d "target/linux/ramips" ]; then
	SRC="$(pwd)"
else
	SRC="$WS/openwrt"
fi
[ -d "$SRC/target/linux/ramips" ] || { echo "!! 找不到 ramips 源码树"; exit 1; }

# ---------- 1. DTS ----------
cat > "$SRC/target/linux/ramips/dts/mt7620a_qianmi_hd51.dts" << 'EOF'
// SPDX-License-Identifier: GPL-2.0-or-later OR MIT

#include "mt7620a.dtsi"

#include <dt-bindings/gpio/gpio.h>
#include <dt-bindings/input/input.h>
#include <dt-bindings/leds/common.h>

/ {
	compatible = "qianmi,hd51", "ralink,mt7620a-soc";
	model = "Qianmi HD51";

	aliases {
		label-mac-device = &ethernet;
	};

	keys {
		compatible = "gpio-keys";

		reset {
			label = "reset";
			gpios = <&gpio0 13 GPIO_ACTIVE_LOW>;
			linux,code = <KEY_RESTART>;
		};
	};
};

&spi0 {
	status = "okay";

	flash@0 {
		compatible = "jedec,spi-nor";
		reg = <0>;
		spi-max-frequency = <24000000>;
		m25p,fast-read;

		partitions {
			compatible = "fixed-partitions";
			#address-cells = <1>;
			#size-cells = <1>;

			partition@0 {
				label = "u-boot";
				reg = <0x0 0x30000>;
				read-only;
			};

			partition@30000 {
				label = "u-boot-env";
				reg = <0x30000 0x10000>;
				read-only;
			};

			factory: partition@40000 {
				label = "factory";
				reg = <0x40000 0x10000>;
				read-only;

				nvmem-layout {
					compatible = "fixed-layout";
					#address-cells = <1>;
					#size-cells = <1>;

					eeprom_factory_0: eeprom@0 {
						reg = <0x0 0x200>;
					};

					macaddr_factory_28: macaddr@28 {
						reg = <0x28 0x6>;
					};
				};
			};

			partition@50000 {
				compatible = "denx,uimage";
				label = "firmware";
				reg = <0x50000 0xfb0000>;
			};
		};
	};
};

&ehci {
	status = "okay";
};

&ohci {
	status = "okay";
};

&ethernet {
	nvmem-cells = <&macaddr_factory_28>;
	nvmem-cell-names = "mac-address";

	mediatek,portmap = "lllll";
};

&wmac {
	/* v9：校准走固件文件通道（已由 v7 实机验证：radio0 显示 MediaTek MT7620、
	   手机连上 192.168.1.242、Rx 104Mbit/s MCS13）。数据烘在
	   /lib/firmware/soc_wmac.eeprom，512 字节，取自原厂 factory 分区。 */
	/delete-property/ ralink,mtd-eeprom;
};

&sdhci {
	/* mt7620A 自带 SD 主机控制器（OpenWrt 有 830-mmc 补丁支持），
	   dtsi 里默认 disabled，这里打开，卡槽若是走 SDHCI 就能直接识卡 */
	status = "okay";
};

&pcie {
	status = "okay";
};
EOF
echo "==> DTS 已写入"

# ---------- 1b. 补 root=：Breed 不传 root，写 flash 的系统必挂 ----------
# 实测 /proc/cmdline 只有 console=ttyS0,57600 rootfstype=squashfs,jffs2，没有 root=
# 内核里已确认带 bootargs-append 支持（OpenWrt 314-MIPS-add-bootargs-override-property.patch）
# mtdsplit(denx,uimage) 把 firmware 切成 kernel=mtd4、rootfs=mtd5，故 root 指向 mtdblock5
DTSI="$SRC/target/linux/ramips/dts/mt7620a.dtsi"
python3 - "$DTSI" << 'PY2'
import sys, re
p = sys.argv[1]
s = open(p).read()
if 'bootargs-append' in s:
    print('dtsi 已有 bootargs-append，跳过'); sys.exit(0)
s2 = s.replace(
    'bootargs = "console=ttyS0,57600";',
    'bootargs = "console=ttyS0,57600";\n\t\tbootargs-append = " root=/dev/mtdblock5 rootfstype=squashfs,jffs2 rootwait";', 1)
if s2 == s:
    print('!! 未匹配到 bootargs 行，bootargs-append 未加'); sys.exit(1)
open(p, 'w').write(s2)
print('dtsi 已加 bootargs-append -> root=/dev/mtdblock5')
PY2

# ---------- 2. 设备定义 ----------
GMK="$SRC/target/linux/ramips/image/mt7620.mk"
if grep -q "^define Device/qianmi_hd51$" "$GMK"; then
	sed -i '/^define Device\/qianmi_hd51$/,/^TARGET_DEVICES += qianmi_hd51$/d' "$GMK"
fi
cat >> "$GMK" << 'EOF'

define Device/qianmi_hd51
  SOC := mt7620a
  IMAGE_SIZE := 16320k
  DEVICE_VENDOR := Qianmi
  DEVICE_MODEL := HD51
  DEVICE_DTS := mt7620a_qianmi_hd51
  DEVICE_PACKAGES := kmod-rt2800-soc kmod-mt76x0e kmod-mt76x2 kmod-usb2 kmod-usb-ohci \
	kmod-usb-storage kmod-fs-exfat kmod-fs-vfat
  SUPPORTED_DEVICES += qianmi,hd51 hd51
endef
TARGET_DEVICES += qianmi_hd51
EOF
echo "==> 设备定义已写入"

# ---------- 3. 交换机：5 口全 LAN（AP/中继形态） ----------
NET="$SRC/target/linux/ramips/mt7620/base-files/etc/board.d/02_network"
[ -f "$NET" ] || { echo "!! 找不到 02_network"; exit 1; }
python3 - "$NET" << 'PY'
import sys
p = sys.argv[1]
s = open(p).read()
if 'qianmi,hd51' in s:
    print('已有 hd51 分支，跳过')
    sys.exit(0)
anchor = "\tasus,rp-n53)\n"
block = (
    "\tqianmi,hd51)\n"
    "\t\tucidef_add_switch \"switch0\" \\\n"
    "\t\t\t\"0:lan\" \"1:lan\" \"2:lan\" \"3:lan\" \"4:lan\" \"6@eth0\"\n"
    "\t\t;;\n"
)
if anchor not in s:
    print('!! 找不到插入锚点'); sys.exit(1)
s = s.replace(anchor, block + anchor, 1)
open(p, 'w').write(s)
print('02_network 已插入 hd51 分支')
PY

# ---------- 4. 默认配置：中文 / 时区 / 开放热点 ----------
mkdir -p "$SRC/files/etc/uci-defaults" "$SRC/files/etc/config"
cat > "$SRC/files/etc/config/network" << 'NETEOF'
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.255.255.0'

config device 'brlan'
	option name 'br-lan'
	option type 'bridge'
	list ports 'eth0'
	list ports 'eth0.1'

config switch
	option name 'switch0'
	option reset '1'
	option enable_vlan '1'

config switch_vlan
	option device 'switch0'
	option vlan '1'
	option ports '0 1 2 3 4 6t'

config interface 'lan'
	option device 'br-lan'
	option proto 'static'
	option ipaddr '192.168.1.1'
	option netmask '255.255.255.0'
	option ip6assign '60'
NETEOF

# v5：无线配置直接烘进镜像，不再依赖首次开机时 `wifi config` 是否能探到 phy。
# 这样即使 phy 命名的先后顺序不同，hostapd 也有确定的配置可用。
cat > "$SRC/files/etc/config/wireless" << 'WIFIEOF'
config wifi-device 'radio0'
	option type 'mac80211'
	option channel '1'
	option band '2g'
	option htmode 'HT20'
	option country 'CN'
	option disabled '0'
	option path 'platform/10180000.wmac'

config wifi-iface 'default_radio0'
	option device 'radio0'
	option network 'lan'
	option mode 'ap'
	option ssid 'HD51'
	option encryption 'none'
	option disabled '0'
WIFIEOF

# v7：把原厂 factory 分区里的无线校准数据烘进镜像（/lib/firmware/soc_wmac.eeprom）
# 数据来源：原厂 dump 百米生活.bin @0x40000 起 0x200 字节
#   WLAN MAC 8c:88:4b:00:53:8a（= 本机 phy0-ap0 实测 addr），ETH MAC 8c:88:4b:00:53:88
#   md5(512字节) = 6b409897e68203b323fd0bbe25aefe74
mkdir -p "$SRC/files/lib/firmware" "$SRC/files/etc"
cat > "$SRC/files/lib/firmware/soc_wmac.eeprom.b64" << 'CALEOF'
IHYFAYyISwBTiv///////////////////////////////////////4yISwBTiIyISwBTiSIMBMD//x4BVXeoqoyI//8KAAAAAAAAAAAA/////xAQDw8ODg4ODw8PDw8PExMTEhISEhMTFBQUFBSA////gP///wAA/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////yD/////////////////CAgICAQABwcEAAgIBAAHBwQA//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8=
CALEOF
base64 -d "$SRC/files/lib/firmware/soc_wmac.eeprom.b64" > "$SRC/files/lib/firmware/soc_wmac.eeprom"
rm -f "$SRC/files/lib/firmware/soc_wmac.eeprom.b64"
echo "烘入校准文件 $(wc -c < "$SRC/files/lib/firmware/soc_wmac.eeprom") 字节"

# 版本标记：浏览器打开 http://192.168.1.1/ver.txt 就能确认烧进去的是哪一版
mkdir -p "$SRC/files/www"
cat > "$SRC/files/www/ver.txt" << 'VEREOF'
HD51 v12
build: 2026-11-15
dts: /delete-property/ ralink,eeprom + ralink,mtd-eeprom = <&factory 0x0>
wireless: baked (/etc/config/wireless, radio0, SSID HD51, open)
sd: &sdhci status=okay
VEREOF

cat > "$SRC/files/etc/uci-defaults/99-hd51-basic" << 'EOF'
#!/bin/sh
uci -q set system.@system[0].hostname='HD51-v12' || true
uci -q set system.@system[0].timezone='CST-8' || true
uci -q set system.@system[0].zonename='Asia/Shanghai' || true
uci -q commit system

# 兜底：万一 phy 不在 radio0 上，按探测结果补一次
[ -f /etc/config/wireless ] || wifi config >/dev/null 2>&1
if [ -f /etc/config/wireless ]; then
	for i in 0 1 2 3; do
		uci -q set wireless.@wifi-iface[$i].ssid="HD51" || true
		uci -q set wireless.@wifi-iface[$i].encryption='none' || true
		uci -q set wireless.@wifi-iface[$i].network='lan' || true
		uci -q set wireless.@wifi-iface[$i].disabled='0' || true
		uci -q set wireless.@wifi-iface[$i].mode='ap' || true
	done
	uci -q set wireless.radio0.disabled='0' || true
	uci -q set wireless.radio0.country='CN' || true
	# 不再对 radio1 做任何 uci set（对不存在的命名段 set 会凭空造出重复 radio）
	# 收尾：删掉自动探测多出来的重复 wifi-device，只保留 radio0
	for s in $(uci -q show wireless | sed -n 's/^wireless\.\(radio[0-9]*\)=wifi-device$/\1/p'); do
		[ "$s" = "radio0" ] && continue
		uci -q delete wireless.$s || true
		uci -q delete wireless.default_$s || true
	done
	uci -q commit wireless
fi

# 兜底登录通道：SSH 密码 hd51（网页/串口都连不上时的最后手段）
printf 'hd51\nhd51\n' | passwd root >/dev/null 2>&1 || true
exit 0
EOF
chmod +x "$SRC/files/etc/uci-defaults/99-hd51-basic"

# ---------- 5. .config 里补包 ----------
CFG="$WS/${CONFIG_FILE:-.config.hd51}"
add_cfg() { grep -q "^$1=y" "$CFG" 2>/dev/null || echo "$1=y" >> "$CFG"; }
add_cfg CONFIG_PACKAGE_luci
add_cfg CONFIG_PACKAGE_luci-base
add_cfg CONFIG_PACKAGE_luci-i18n-base-zh-cn
add_cfg CONFIG_PACKAGE_wpad-basic-mbedtls
add_cfg CONFIG_PACKAGE_iw
add_cfg CONFIG_PACKAGE_iperf3
add_cfg CONFIG_PACKAGE_luci-app-commands
add_cfg CONFIG_PACKAGE_kmod-mt7620
add_cfg CONFIG_PACKAGE_kmod-mt76x0e
add_cfg CONFIG_PACKAGE_kmod-mt76x2
add_cfg CONFIG_PACKAGE_kmod-usb2
add_cfg CONFIG_PACKAGE_kmod-usb-ohci
add_cfg CONFIG_PACKAGE_kmod-gpio-button-hotplug
add_cfg CONFIG_PACKAGE_kmod-usb-storage
add_cfg CONFIG_PACKAGE_kmod-fs-exfat
add_cfg CONFIG_DEVMEM
add_cfg CONFIG_BUSYBOX_CONFIG_DEVMEM
echo "==> .config 已补包（$CFG）"

# ---------- 6. 硬件自检：开机自动生成 /www/probe.html ----------
PROBE="$SRC/files/usr/bin/hd51-probe.sh"
mkdir -p "$SRC/files/usr/bin" "$SRC/files/www/cgi-bin" "$SRC/files/etc/init.d"

cat > "$PROBE" << 'PROBE_EOF'
#!/bin/sh
# HD51 自检探测：结果写到 /www/probe.html（手机浏览器直接看）
T=/tmp/probe.raw
: > "$T"
sec() { printf '\n===== %s =====\n' "$1" >> "$T"; }
run() { printf '\n$ %s\n' "$*" >> "$T"; ( "$@" ) >> "$T" 2>&1 || echo "[失败]" >> "$T"; }
hx() {
	if command -v hexdump >/dev/null 2>&1; then
		dd if="$1" bs=1 count="${2:-64}" 2>/dev/null | hexdump -C >> "$T"
	else
		dd if="$1" bs=1 count="${2:-64}" 2>/dev/null | od -An -tx1 >> "$T" 2>/dev/null
	fi
}

sec "0 基本信息"
run date
run uname -a
run cat /etc/openwrt_release
run cat /proc/cmdline

sec "1 CPU 与内存"
run sh -c "head -n 60 /proc/cpuinfo"
run free
run sh -c "head -n 12 /proc/meminfo"

sec "2 闪存与分区表"
run cat /proc/mtd
run sh -c "dmesg | grep -iE 'spi-nor|jedec|mx25|m25p|nand|mtd[0-9]' | head -n 40"

sec "3 引导器取证（Breed / u-boot）"
printf '\n--- /dev/mtd0 前 64 字节 ---\n' >> "$T"
hx /dev/mtd0 64
run sh -c "dd if=/dev/mtd0 bs=1024 count=192 2>/dev/null | tr -c '[:print:]' '\n' | grep -iE 'Breed|breed|r1[0-9][0-9][0-9]|mt7620|layout|offset|u-boot|U-Boot' | head -n 25"

sec "4 u-boot-env / mtd1"
hx /dev/mtd1 64
run sh -c "dd if=/dev/mtd1 bs=1024 count=64 2>/dev/null | tr -c '[:print:]' '\n' | grep -iE 'bootcmd|bootdelay|ipaddr|serverip|ip=|CurrentImage|Image1Try|RestFlag|baud|layout' | head -n 30"

sec "5 PCI 总线（5G 芯片关键）"
run lspci
run lspci -nn
run sh -c "for d in /sys/bus/pci/devices/*; do v=\$(cat \$d/vendor 2>/dev/null); p=\$(cat \$d/device 2>/dev/null); drv=\$(basename \$(readlink \$d/driver 2>/dev/null) 2>/dev/null); echo \"\$d vendor=\$v device=\$p driver=\$drv\"; done"
run sh -c "ls /sys/bus/pci/drivers 2>/dev/null"

sec "6 无线子系统"
run iw dev
run sh -c "ls -l /sys/class/ieee80211 2>/dev/null; for p in /sys/class/ieee80211/*; do echo \"== \$p\"; readlink \$p/device 2>/dev/null; done"
run sh -c "dmesg | grep -iE 'mt76|mt7610|mt7612|rt2x00|phy[0-9]|eeprom|calib|ieee80211' | head -n 40"
run uci show wireless

sec "7 交换机"
run sh -c "swconfig dev switch0 show 2>/dev/null | head -n 60"

sec "8 GPIO / 按键 / LED"
run sh -c "mount -t debugfs none /sys/kernel/debug 2>/dev/null; head -n 60 /sys/kernel/debug/gpio 2>/dev/null || echo 'debugfs gpio 不可读'"
run sh -c "ls /sys/class/leds 2>/dev/null; for l in /sys/class/leds/*; do echo \"== \$l\"; head -n 1 \$l/trigger 2>/dev/null; done"
run sh -c "ls /proc/device-tree 2>/dev/null | head -n 40"
run sh -c "cat /proc/device-tree/keys/reset/label 2>/dev/null; echo"

sec "9 SD / USB"
run sh -c "dmesg | grep -iE 'mmc|sdhci|usb-storage|scsi|uas' | head -n 40"
run sh -c "ls -l /dev/sd* /dev/mmcblk* /dev/disk/by-id 2>/dev/null"

sec "10 网络"
run sh -c "ifconfig -a"
run sh -c "ip addr show"

sec "11 dmesg 尾部"
run sh -c "dmesg | tail -n 80"

# 生成网页
{
	printf '%s\n' '<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>HD51 自检</title><style>body{margin:0;padding:10px;background:#0f1216;color:#dfe7ef;font:13px/1.5 monospace}h1{color:#6ad}h2{color:#fc6}p{color:#9ab}pre{white-space:pre-wrap;word-break:break-all;background:#151a20;padding:10px;border-radius:6px}</style></head><body>'
	printf '%s\n' '<h1>HD51 硬件自检</h1><p>把本页整页截图发回即可；GPIO 点灯：/cgi-bin/gpio?n=13&amp;v=1</p><pre>'
	sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "$T"
	printf '%s\n' '</pre></body></html>'
} > /www/probe.html
cp "$T" /www/probe.txt
echo "probe 完成 $(date)"
PROBE_EOF
chmod +x "$PROBE"

cat > "$SRC/files/etc/init.d/hd51probe" << 'INIT_EOF'
#!/bin/sh /etc/rc.common
START=99
start() { ( sleep 25; /usr/bin/hd51-probe.sh ) >/dev/null 2>&1 & }
boot() { start; }
INIT_EOF
chmod +x "$SRC/files/etc/init.d/hd51probe"

cat > "$SRC/files/www/cgi-bin/gpio" << 'CGI_EOF'
#!/bin/sh
printf 'Content-Type: text/plain; charset=utf-8\n\n'
N=""; V=""
for kv in $(echo "$QUERY_STRING" | tr '&' ' '); do
	case "$kv" in
		n=*) N="${kv#n=}";;
		v=*) V="${kv#v=}";;
	esac
done
[ -n "$N" ] || { echo "用法: /cgi-bin/gpio?n=13&v=1  (v=1 高电平, v=0 低电平, v=i 读输入)"; exit 0; }
[ -d "/sys/class/gpio/gpio$N" ] || echo "$N" > /sys/class/gpio/export 2>/dev/null
[ -d "/sys/class/gpio/gpio$N" ] || { echo "GPIO$N 导出失败（多半已被驱动占用）"; exit 1; }
if [ "${V:-i}" = "i" ]; then
	echo in > "/sys/class/gpio/gpio$N/direction" 2>/dev/null
	echo "GPIO$N 输入值 = $(cat /sys/class/gpio/gpio$N/value)"
else
	echo out > "/sys/class/gpio/gpio$N/direction" 2>/dev/null
	echo "$V" > "/sys/class/gpio/gpio$N/value" 2>/dev/null
	echo "GPIO$N 已设为输出 = $V"
fi
CGI_EOF
chmod +x "$SRC/files/www/cgi-bin/gpio"
echo "==> 自检脚本已写入（probe.html + cgi 点灯）"

# ---------- 7. v10：发射/接收寄存器实时读写口（devmem 直捅 wmac 寄存器区） ----------
# 目的：不再靠"再刷一版"来试参数。MAC 寄存器区基址 0x10180000（dmesg: platform/10180000.wmac），
# RF_CONTROL0..3 = +0x518/+0x520/+0x528/+0x530，RF_BYPASS0..3 = +0x51c/+0x524/+0x52c/+0x534
cat > "$SRC/files/www/cgi-bin/reg" << 'REG_EOF'
#!/bin/sh
printf 'Content-Type: text/plain; charset=utf-8\n\n'
BASE=0x10180000
for kv in $(echo "$QUERY_STRING" | tr '&' ' '); do
	case "$kv" in
		off=*) OFF="${kv#off=}";;
		val=*) VAL="${kv#val=}";;
	esac
done
[ -n "$OFF" ] || {
	echo "用法: /cgi-bin/reg?off=0x530            (读)"
	echo "      /cgi-bin/reg?off=0x530&val=0x101   (写)"
	echo ""
	echo "常用: 0x518/0x51c RF_CONTROL0/BYPASS0"
	echo "      0x520/0x524 RF_CONTROL1/BYPASS1"
	echo "      0x528/0x52c RF_CONTROL2/BYPASS2"
	echo "      0x530/0x534 RF_CONTROL3/BYPASS3"
	echo ""
	echo "--- 当前值 ---"
	for o in 518 51c 520 524 528 52c 530 534; do
		v=$(devmem $((BASE + 0x$o)) 2>/dev/null)
		echo "0x$o = $v"
	done
	exit 0
}
ADDR=$((BASE + OFF))
if [ -n "$VAL" ]; then
	OUT=$(devmem $ADDR 32 $VAL 2>&1)
	echo "写 $OFF = $VAL : $OUT"
fi
echo "$OFF 现在 = $(devmem $ADDR 32 2>/dev/null)"
REG_EOF
chmod +x "$SRC/files/www/cgi-bin/reg"

# ---------- 8. v10：实时诊断页 /cgi-bin/diag（每次刷新都是当前状态） ----------
cat > "$SRC/files/www/cgi-bin/diag" << 'DIAG_EOF'
#!/bin/sh
printf 'Content-Type: text/plain; charset=utf-8\n\n'
echo "===== 时间 ====="
echo "uptime(秒) = $(cut -d' ' -f1 /proc/uptime)"
date
echo
echo "===== 无线接口 ====="
iw dev 2>&1
echo
echo "===== 已连接站点（AP 收到的 dBm 在这里） ====="
iw dev phy0-ap0 station dump 2>&1 | head -n 40
echo
echo "===== 发射计数（beacon 有没有真发出去） ====="
for f in tx_packets tx_bytes tx_errors rx_packets rx_bytes; do
	printf '%-12s %s\n' "$f" "$(cat /sys/class/net/phy0-ap0/statistics/$f 2>/dev/null)"
done
echo
echo "===== RF 控制寄存器（可能藏着 PA/LNA 路径开关） ====="
for o in 518 51c 520 524 528 52c 530 534; do
	v=$(devmem $((0x10180000 + 0x$o)) 32 2>/dev/null)
	printf '0x%s = %s\n' "$o" "$v"
done
echo
echo "===== 启动时序 ====="
cat /www/timeline.txt 2>/dev/null
echo
echo "===== dmesg 无线相关 ====="
dmesg | grep -iE 'rt2x00|rt28|phy0|calib|eeprom|br-lan' | tail -n 40
DIAG_EOF
chmod +x "$SRC/files/www/cgi-bin/diag"

# ---------- 9. v10：启动时序打点（全部用内核 uptime 秒，最准） ----------
mkdir -p "$SRC/files/etc/init.d"
for n in 05 15 25 40 60 80 95; do
cat > "$SRC/files/etc/init.d/hd51m$n" << MARK_EOF
#!/bin/sh /etc/rc.common
START=$n
start() {
	echo "[\$(cut -d' ' -f1 /proc/uptime)s] init.d START=$n" >> /www/timeline.txt
}
boot() { start; }
MARK_EOF
chmod +x "$SRC/files/etc/init.d/hd51m$n"
done

cat > "$SRC/files/usr/bin/hd51-watch.sh" << 'W_EOF'
#!/bin/sh
# 一直盯着 phy0-ap0：出现的那一刻、以及进入 forwarding 的那一刻都打点
T=/www/timeline.txt
: > "$T"
echo "$(cut -d' ' -f1 /proc/uptime) watchdog-start" >> "$T"
i=0
while [ $i -lt 600 ]; do
	if [ -e /sys/class/net/phy0-ap0/statistics ]; then
		if [ ! -f /tmp/.ap0seen ]; then
			echo "$(cut -d' ' -f1 /proc/uptime) phy0-ap0 出现" >> "$T"
			touch /tmp/.ap0seen
		fi
	fi
	if dmesg | grep -q "port 3(phy0-ap0) entered forwarding"; then
		if [ ! -f /tmp/.fwdseen ]; then
			echo "$(cut -d' ' -f1 /proc/uptime) br-lan forwarding" >> "$T"
			touch /tmp/.fwdseen
			break
		fi
	fi
	sleep 1
	i=$((i+1))
done
echo "$(cut -d' ' -f1 /proc/uptime) watchdog-exit" >> "$T"
W_EOF
chmod +x "$SRC/files/usr/bin/hd51-watch.sh"

cat > "$SRC/files/etc/init.d/hd51watch" << 'WI_EOF'
#!/bin/sh /etc/rc.common
START=01
start() { ( /usr/bin/hd51-watch.sh ) >/dev/null 2>&1 & }
boot() { start; }
WI_EOF
chmod +x "$SRC/files/etc/init.d/hd51watch"
echo "==> v10 诊断/打点/kernel 调试口 已写入"

# ---------- 10. v11：内核小模块 /proc/hd51reg（不依赖 busybox devmem） ----------
PKGD="$SRC/package/hd51reg"
mkdir -p "$PKGD/src"
cat > "$PKGD/Makefile" << 'PKG_EOF'
include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=hd51reg
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define KernelPackage/hd51reg
  SUBMENU:=Other modules
  TITLE:=HD51 wmac register poking
  FILES:=$(PKG_BUILD_DIR)/hd51reg.ko
  AUTOLOAD:=$(call AutoLoad,90,hd51reg)
endef

define KernelPackage/hd51reg/description
 HD51 debug: read/write MT7620 wmac MAC registers via /proc/hd51reg
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(MAKE) -C "$(LINUX_DIR)" $(KERNEL_MAKE_FLAGS) M="$(PKG_BUILD_DIR)" modules
endef

$(eval $(call KernelPackage,hd51reg))
PKG_EOF

printf 'obj-m += hd51reg.o\n' > "$PKGD/src/Makefile"

cat > "$PKGD/src/hd51reg.c" << 'C_EOF'
// SPDX-License-Identifier: GPL-2.0
#include <linux/module.h>
#include <linux/proc_fs.h>
#include <linux/io.h>
#include <linux/uaccess.h>
#include <linux/seq_file.h>
#include <linux/kernel.h>
#include <linux/string.h>
#include <linux/types.h>

#define WMAC_PHYS 0x10180000
#define WMAC_SIZE 0x0800

static void __iomem *base;
static char last[64] = "no-write-yet\n";

static int hd51_show(struct seq_file *m, void *v)
{
	u32 off;
	seq_printf(m, "last: %s", last);
	seq_puts(m, "REG  ADDR        VALUE\n");
	for (off = 0x500; off <= 0x540; off += 4)
		seq_printf(m, "0x%03x 0x%08x 0x%08x\n", off,
			   WMAC_PHYS + off, readl(base + off));
	seq_puts(m, "\n用法: echo \"w 0x530 0x101\" > /proc/hd51reg\n");
	return 0;
}
static int hd51_open(struct inode *i, struct file *f)
{
	return single_open(f, hd51_show, NULL);
}
static ssize_t hd51_write(struct file *f, const char __user *buf,
			  size_t len, loff_t *off)
{
	char tmp[64];
	char *p, *tok;
	unsigned long addr = 0, val = 0;
	int rc;

	if (len >= sizeof(tmp))
		return -EINVAL;
	if (copy_from_user(tmp, buf, len))
		return -EFAULT;
	tmp[len] = 0;

	p = tmp;
	tok = strsep(&p, " \t\n");
	if (!tok || tok[0] != 'w' || tok[1] != 0)
		return -EINVAL;
	tok = strsep(&p, " \t\n");
	if (!tok)
		return -EINVAL;
	rc = kstrtoul(tok, 0, &addr);
	if (rc)
		return -EINVAL;
	tok = strsep(&p, " \t\n");
	if (!tok)
		return -EINVAL;
	rc = kstrtoul(tok, 0, &val);
	if (rc)
		return -EINVAL;
	if (addr > WMAC_SIZE - 4)
		return -EINVAL;

	writel((u32)val, base + addr);
	scnprintf(last, sizeof(last), "wrote 0x%lx=0x%lx, readback 0x%08x\n",
		  addr, val, readl(base + addr));
	return len;
}
static const struct proc_ops hd51_pops = {
	.proc_open	= hd51_open,
	.proc_read	= seq_read,
	.proc_lseek	= seq_lseek,
	.proc_release	= single_release,
	.proc_write	= hd51_write,
};
static int __init hd51reg_init(void)
{
	base = ioremap(WMAC_PHYS, WMAC_SIZE);
	if (!base)
		return -ENOMEM;
	if (!proc_create("hd51reg", 0644, NULL, &hd51_pops)) {
		iounmap(base);
		return -ENOMEM;
	}
	pr_info("hd51reg: wmac mapped, /proc/hd51reg ready\n");
	return 0;
}
static void __exit hd51reg_exit(void)
{
	remove_proc_entry("hd51reg", NULL);
	iounmap(base);
}
module_init(hd51reg_init);
module_exit(hd51reg_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("HD51 wmac register poking");
C_EOF

add_cfg CONFIG_PACKAGE_kmod-hd51reg

cat > "$SRC/files/www/cgi-bin/reg" << 'REG_EOF'
#!/bin/sh
printf 'Content-Type: text/plain; charset=utf-8\n\n'
OFF=""; VAL=""
for kv in $(echo "$QUERY_STRING" | tr '&' ' '); do
	case "$kv" in
		off=*) OFF="${kv#off=}";;
		val=*) VAL="${kv#val=}";;
	esac
done
[ -e /proc/hd51reg ] || { echo "/proc/hd51reg 不存在"; lsmod | grep hd51reg; exit 1; }
if [ -n "$OFF" ] && [ -n "$VAL" ]; then
	echo "w $OFF $VAL" > /proc/hd51reg && echo "已写: $OFF = $VAL"
fi
cat /proc/hd51reg
REG_EOF
chmod +x "$SRC/files/www/cgi-bin/reg"
echo "==> v11 内核模块 + reg 页 已写入"

# ---------- 11. v12：diagnostics 页整段重写（寄存器走 /proc/hd51reg，不再用 devmem） ----------
cat > "$SRC/files/www/cgi-bin/diag" << 'DIAG_EOF'
#!/bin/sh
printf 'Content-Type: text/plain; charset=utf-8\n\n'
echo "===== 时间 ====="
echo "uptime(秒) = $(cut -d' ' -f1 /proc/uptime)"
date
echo
echo "===== 无线接口 ====="
iw dev 2>&1
echo
echo "===== 已连接站点（AP 收到的 dBm 在这里） ====="
iw dev phy0-ap0 station dump 2>&1 | head -n 45
echo
echo "===== 接口收发计数（tx_packets 涨 = beacon 真发出去了） ====="
for f in tx_packets tx_bytes tx_errors rx_packets rx_bytes rx_errors; do
	printf '%-12s %s\n' "$f" "$(cat /sys/class/net/phy0-ap0/statistics/$f 2>/dev/null)"
done
echo
echo "===== RF 寄存器（/proc/hd51reg） ====="
if [ -e /proc/hd51reg ]; then
	cat /proc/hd51reg
else
	echo "kmod-hd51reg 未加载"
	lsmod 2>/dev/null | grep -i hd51reg
fi
echo
echo "===== 启动时序（uptime 秒） ====="
cat /www/timeline.txt 2>/dev/null
echo
echo "===== dmesg 无线相关 ====="
dmesg 2>/dev/null | grep -iE 'rt2x00|rt28|phy0|calib|eeprom|br-lan' | tail -n 40
DIAG_EOF
chmod +x "$SRC/files/www/cgi-bin/diag"
echo "==> v12 diag 页已重写（寄存器走 /proc/hd51reg）"



