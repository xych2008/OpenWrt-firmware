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
IHYFAYyISwBTiv///////////////////////////////////////4yISwBTiIyISwBTiSIMBMD/
/x4BVXeoqoyI//8KAAAAAAAAAAAA/////xAQDw8ODg4ODw8PDw8PExMTEhISEhMTFBQUFBSA////
gP///wAA////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////yD/////////////////CAgICAQA
BwcEAAgIBAAHBwQA////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////////////////8=
CALEOF
base64 -d "$SRC/files/lib/firmware/soc_wmac.eeprom.b64" > "$SRC/files/lib/firmware/soc_wmac.eeprom"
rm -f "$SRC/files/lib/firmware/soc_wmac.eeprom.b64"
echo "烘入校准文件 $(wc -c < "$SRC/files/lib/firmware/soc_wmac.eeprom") 字节"

# 版本标记：浏览器打开 http://192.168.1.1/ver.txt 就能确认烧进去的是哪一版
mkdir -p "$SRC/files/www"
cat > "$SRC/files/www/ver.txt" << 'VEREOF'
HD51 v18
build: 2026-11-15
dts: /delete-property/ ralink,eeprom + ralink,mtd-eeprom = <&factory 0x0>
wireless: baked (/etc/config/wireless, radio0, SSID HD51, open)
sd: &sdhci status=okay
VEREOF

cat > "$SRC/files/etc/uci-defaults/99-hd51-basic" << 'EOF'
#!/bin/sh
uci -q set system.@system[0].hostname='HD51-v16' || true
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
printf 'Content-Type: text/html; charset=utf-8\n\n'
html_head() {
cat << 'H'
<!DOCTYPE html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>HD51 射频调试台</title>
<style>
body{font-family:sans-serif;margin:0;padding:12px;background:#f7f7f7;color:#111}
h2{margin:6px 0 12px}
a.b{display:inline-block;margin:3px;padding:9px 13px;background:#1a73e8;color:#fff;
border-radius:6px;text-decoration:none;font-size:15px}
a.g{background:#0b8f3f}a.r{background:#c0392b}a.k{background:#555}
.wrap{display:flex;flex-wrap:wrap;margin:8px 0 14px}
pre{background:#fff;border:1px solid #ddd;padding:10px;overflow:auto;font-size:13px;line-height:1.45}
h3{margin:16px 0 4px;font-size:16px}
</style></head><body>
H
}
html_head
echo "<h2>HD51 射频调试台 <small>$(cat /www/ver.txt 2>/dev/null | head -1)</small></h2>"

# 动作
for kv in $(echo "$QUERY_STRING" | tr '&' ' '); do
	case "$kv" in
		d=*) D="${kv#d=}";;
		v=*) V="${kv#v=}";;
		r=*) R="${kv#r=}";;
	esac
done
if echo "$QUERY_STRING" | grep -q "act=tx&"; then
	echo "tx $D" > /proc/hd51reg 2>/dev/null
	echo "<p style='color:#0b8f3f;font-weight:bold'>已执行：TX 功率字段 + $D</p>"
fi
if echo "$QUERY_STRING" | grep -q "act=txset"; then
	echo "txset $V" > /proc/hd51reg 2>/dev/null
	echo "<p style='color:#0b8f3f;font-weight:bold'>已执行：TX 功率字段 = $V</p>"
fi
if echo "$QUERY_STRING" | grep -q "act=bit20"; then
	echo "bit20 $V" > /proc/hd51reg 2>/dev/null
	echo "<p style='color:#0b8f3f;font-weight:bold'>已执行：GPIO_MODE bit20 = $V</p>"
fi
if echo "$QUERY_STRING" | grep -q "act=bbp"; then
	echo "bbp $R $V" > /proc/hd51reg 2>/dev/null
	echo "<p style='color:#0b8f3f;font-weight:bold'>已执行：BBP[$R] = $V</p>"
fi

echo '<h3>一键调功率（点一下立即生效，改完看手机信号格）</h3><div class="wrap">'
for d in 2 4 6 8 10 12 -4 -8; do
	echo "<a class=g href=\"/cgi-bin/reg?act=tx&d=$d\">TX $d</a>"
done
echo "<a class=k href=\"/cgi-bin/reg\">刷新</a></div>"

echo '<h3>直接设成固定档位</h3><div class="wrap">'
for v in 16 20 24 28 32 36 40 48; do
	echo "<a class=b href=\"/cgi-bin/reg?act=txset&v=$v\">设 $v</a>"
done
echo "</div><p><small>字段含义：6bit，0~63。**相对增量才有用**（点 TX +6 实测满格）；
下半排"设 16~48"是绝对档位，设大反而更弱，仅作对照实验。</small></p>"

echo '<h3>BBP 关键寄存器微调</h3><div class="wrap">'
echo "<a class=b href=\"/cgi-bin/reg?act=bbp&r=66&v=0x1c\">BBP66=0x1c</a>"
echo "<a class=b href=\"/cgi-bin/reg?act=bbp&r=66&v=0x0c\">BBP66=0x0c</a>"
echo "<a class=b href=\"/cgi-bin/reg?act=bbp&r=66&v=0x2c\">BBP66=0x2c</a>"
echo "</div>"

echo '<h3>SoC 针脚（原厂驱动会动态切换第 20 脚）</h3><div class="wrap">'
echo "<a class=b href=\"/cgi-bin/reg?act=bit20&v=0\">清 bit20（厂商 ExtPA 做法）</a>"
echo "<a class=r href=\"/cgi-bin/reg?act=bit20&v=1\">置 bit20（GPIO 模式）</a>"
echo '</div>'
echo '<h3>当前寄存器</h3><pre>'
cat /proc/hd51reg 2>/dev/null || echo "/proc/hd51reg 不存在（模块没加载）"
echo '</pre>'
echo '<h3>已连接站点</h3><pre>'
iw dev phy0-ap0 station dump 2>&1 | grep -E "Station|signal|bitrate|rx bytes|tx bytes" | head -20
echo '</pre></body></html>'
REG_EOF
chmod +x "$SRC/files/www/cgi-bin/reg"

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
// HD51 debug helper: /proc/hd51reg
//  - raw MAC register dump/read/write (window 0x10180000 + 0x0000..0x1fff)
//  - BBP register read/write through BBP_CSR_CFG (0x101c)
//  - TX_PWR_CFG_{0..9} 6-bit field boost / set
#include <linux/module.h>
#include <linux/proc_fs.h>
#include <linux/io.h>
#include <linux/uaccess.h>
#include <linux/seq_file.h>
#include <linux/kernel.h>
#include <linux/string.h>
#include <linux/types.h>
#include <linux/delay.h>
#include <linux/errno.h>

#define WMAC_PHYS 0x10180000
#define WMAC_SIZE 0x4000
#define SYSC_PHYS 0x10000000
#define SYSC_SIZE 0x1000

#define R_BBP_CSR_CFG   0x101c
#define BBP_VALUE       (0xffu)
#define BBP_REGNUM      (0xffu << 8)
#define BBP_READ_CTRL   (1u << 16)
#define BBP_BUSY        (1u << 17)
#define BBP_RW_MODE     (1u << 19)

static void __iomem *base;
static void __iomem *sysc;
static char last[96] = "no-write-yet\n";

static const u16 txpwr_regs[10] = {
	0x1314, 0x1318, 0x131c, 0x1320, 0x1324,
	0x1384, 0x1388,
	0x13d4, 0x13d8, 0x13dc,
};

static inline int bbp_wait(void)
{
	int i;
	for (i = 0; i < 200; i++) {
		if (!(readl(base + R_BBP_CSR_CFG) & BBP_BUSY))
			return 0;
		udelay(5);
	}
	return -ETIMEDOUT;
}

static u8 bbp_read(u16 reg)
{
	u32 v;
	bbp_wait();
	writel(((reg & 0xff) << 8) | BBP_READ_CTRL | BBP_BUSY | BBP_RW_MODE,
	       base + R_BBP_CSR_CFG);
	bbp_wait();
	v = readl(base + R_BBP_CSR_CFG);
	return (u8)(v & BBP_VALUE);
}

static int bbp_write(u16 reg, u8 val)
{
	if (bbp_wait())
		return -ETIMEDOUT;
	writel((val & BBP_VALUE) | ((reg & 0xff) << 8) | BBP_BUSY | BBP_RW_MODE,
	       base + R_BBP_CSR_CFG);
	return bbp_wait();
}

static void txpwr_dump(struct seq_file *m)
{
	u16 i, k;
	u32 v, f;

	seq_puts(m, "TX_PWR_CFG (6bit fields, 0..63):\n");
	for (i = 0; i < 10; i++) {
		v = readl(base + txpwr_regs[i]);
		seq_printf(m, "  cfg%-2d @0x%04x = 0x%08x  ", i, txpwr_regs[i], v);
		for (k = 0; k < 4; k++) {
			f = (v >> (k * 8)) & 0x3f;
			seq_printf(m, "%2u ", f);
		}
		seq_puts(m, "\n");
	}
}

static int txpwr_apply(int delta, int absolute)
{
	u16 i, k;
	u32 v, nv, f;
	int nf;

	for (i = 0; i < 10; i++) {
		v = readl(base + txpwr_regs[i]);
		if (v == 0xffffffff || v == 0)
			continue;
		nv = v;
		for (k = 0; k < 4; k++) {
			f = (v >> (k * 8)) & 0x3f;
			nf = absolute ? delta : (int)f + delta;
			if (nf < 0)
				nf = 0;
			if (nf > 0x3f)
				nf = 0x3f;
			nv &= ~(0x3fu << (k * 8));
			nv |= ((u32)nf & 0x3f) << (k * 8);
		}
		if (nv != v)
			writel(nv, base + txpwr_regs[i]);
	}
	return 0;
}

static int hd51_show(struct seq_file *m, void *unused)
{
	u32 off;
	static u16 bbps[] = { 1, 4, 20, 66, 86, 105, 241 };
	unsigned int i;

	seq_printf(m, "last: %s\n", last);
	seq_puts(m, "--- MAC 寄存器 0x500..0x540 ---\n");
	for (off = 0x500; off <= 0x540; off += 4)
		seq_printf(m, "0x%03x  0x%08x\n", off, readl(base + off));

	seq_printf(m, "--- BBP_CSR_CFG @0x101c = 0x%08x ---\n",
		   readl(base + R_BBP_CSR_CFG));

	txpwr_dump(m);

	seq_puts(m, "--- SoC SYSC / GPIO ---\n");
	seq_printf(m, "0x1000000c (SYSC)      = 0x%08x\n", readl(sysc + 0x0c));
	seq_printf(m, "0x10000010 (SYSC)      = 0x%08x\n", readl(sysc + 0x10));
	seq_printf(m, "0x10000060 (GPIO_MODE)= 0x%08x   bit20=%d\n",
		   readl(sysc + 0x60), (readl(sysc + 0x60) >> 20) & 1);
	for (off = 0x600; off <= 0x640; off += 4)
		seq_printf(m, "0x1000%03x (GPIO)      = 0x%08x\n", off,
			   readl(sysc + off));

	seq_puts(m, "--- BBP 关键寄存器 ---\n");
	for (i = 0; i < ARRAY_SIZE(bbps); i++)
		seq_printf(m, "BBP[%3u] = 0x%02x\n", bbps[i], bbp_read(bbps[i]));

	seq_puts(m, "\n命令(写入 /proc/hd51reg)：\n"
		    "  w <addr> <val>       原始 MAC 写，如 w 0x530 0x101\n"
		    "  bbp <reg> <val>      BBP 写，如 bbp 66 0x1c\n"
		    "  tx <delta>           TX_PWR_CFG 每个 6bit 字段加 delta（可负），如 tx 6\n"
		    "  txset <val>          TX_PWR_CFG 每个字段直接设为 val，如 txset 30\n");
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
	unsigned long a = 0, b = 0;
	long sval = 0;
	int rc;

	if (len >= sizeof(tmp))
		return -EINVAL;
	if (copy_from_user(tmp, buf, len))
		return -EFAULT;
	tmp[len] = 0;
	p = tmp;
	tok = strsep(&p, " \t\n");
	if (!tok)
		return -EINVAL;

	if (!strcmp(tok, "w")) {
		char *t1 = strsep(&p, " \t\n"), *t2 = strsep(&p, " \t\n");
		if (!t1 || !t2)
			return -EINVAL;
		if (kstrtoul(t1, 0, &a) || kstrtoul(t2, 0, &b))
			return -EINVAL;
		if (a > WMAC_SIZE - 4)
			return -EINVAL;
		writel((u32)b, base + a);
		scnprintf(last, sizeof(last), "W 0x%lx=0x%lx -> 0x%08x\n",
			  a, b, readl(base + a));
		return len;
	}

	if (!strcmp(tok, "bbp")) {
		char *t1 = strsep(&p, " \t\n"), *t2 = strsep(&p, " \t\n");
		if (!t1 || !t2)
			return -EINVAL;
		if (kstrtoul(t1, 0, &a) || kstrtoul(t2, 0, &b))
			return -EINVAL;
		if (a > 0xff)
			return -EINVAL;
		rc = bbp_write((u16)a, (u8)b);
		if (rc)
			return rc;
		scnprintf(last, sizeof(last), "BBP[%lu]=0x%02lx -> readback 0x%02x\n",
			  a, b, bbp_read((u16)a));
		return len;
	}

	if (!strcmp(tok, "sysc")) {
		char *t1 = strsep(&p, " \t\n"), *t2 = strsep(&p, " \t\n");
		if (!t1 || !t2)
			return -EINVAL;
		if (kstrtoul(t1, 0, &a) || kstrtoul(t2, 0, &b))
			return -EINVAL;
		if (a > SYSC_SIZE - 4)
			return -EINVAL;
		writel((u32)b, sysc + a);
		scnprintf(last, sizeof(last), "SYSC 0x%lx=0x%lx -> 0x%08x\n",
			  a, b, readl(sysc + a));
		return len;
	}

	if (!strcmp(tok, "bit20")) {
		char *t1 = strsep(&p, " \t\n");
		u32 v;
		if (!t1)
			return -EINVAL;
		if (kstrtoul(t1, 0, &b))
			return -EINVAL;
		v = readl(sysc + 0x60);
		if (b)
			v |= (1u << 20);
		else
			v &= ~(1u << 20);
		writel(v, sysc + 0x60);
		scnprintf(last, sizeof(last), "GPIO_MODE bit20=%lu -> 0x%08x\n",
			  b, readl(sysc + 0x60));
		return len;
	}

	if (!strcmp(tok, "tx") || !strcmp(tok, "txset")) {
		char *t1 = strsep(&p, " \t\n");
		if (!t1)
			return -EINVAL;
		if (kstrtol(t1, 0, &sval))
			return -EINVAL;
		if (sval < -63 || sval > 63)
			return -EINVAL;
		txpwr_apply((int)sval, !strcmp(tok, "txset"));
		scnprintf(last, sizeof(last), "%s %ld applied\n", tok, sval);
		return len;
	}

	return -EINVAL;
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
	sysc = ioremap(SYSC_PHYS, SYSC_SIZE);
	if (!base || !sysc) {
		if (base) iounmap(base);
		if (sysc) iounmap(sysc);
		return -ENOMEM;
	}
	if (!proc_create("hd51reg", 0644, NULL, &hd51_pops)) {
		iounmap(base);
	iounmap(sysc);
		return -ENOMEM;
	}
	pr_info("hd51reg: mapped 0x%x+0x%x, /proc/hd51reg ready\n",
		WMAC_PHYS, WMAC_SIZE);
	return 0;
}

static void __exit hd51reg_exit(void)
{
	remove_proc_entry("hd51reg", NULL);
	iounmap(base);
	iounmap(sysc);
}

module_init(hd51reg_init);
module_exit(hd51reg_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("HD51 wmac register / BBP / TX power helper");
C_EOF

add_cfg CONFIG_PACKAGE_kmod-hd51reg

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

# ---------- 12. v18：启动耗时记录（不改任何功率） ----------
mkdir -p "$SRC/files/etc/init.d"
cat > "$SRC/files/etc/init.d/hd51rf" << 'RF_EOF'
#!/bin/sh /etc/rc.common
START=10
LOG=/www/bootlog.txt
log() { echo "$(cut -d' ' -f1 /proc/uptime)s  $*" >> $LOG; }
start() {
	echo "hd51rf v18 boot" > $LOG
	log "rc 起点"
	( i=0; while [ ! -e /sys/class/net/phy0-ap0 ] && [ $i -lt 400 ]; do sleep 1; i=$((i+1)); done
	  log "phy0-ap0 出现（AP 此刻开始广播）"
	  dmesg > /www/dmesg.txt 2>/dev/null
	  log "dmesg 已存 /www/dmesg.txt" ) &
}
boot() { start; }
stop() { :; }
RF_EOF
chmod +x "$SRC/files/etc/init.d/hd51rf"
echo "==> v18 启动记录脚本已写入"
# ---------- 13. v18：上游 rt2x00 MT7620 补丁（外置 PA/LNA 支持） ----------
mkdir -p "$SRC/target/linux/ramips/patches-5.15"
cat > "$SRC/target/linux/ramips/patches-5.15/992-rt2x00-more-fixes.patch" << 'P992'
From: Daniel Golle <daniel@makrotopia.org>
Date: Mon, 12 Sep 2022 21:33:13 +0100
Subject: [PATCH] rt2x00: various experimental fixes for MT7620

Serge Vasilugin reports:

To improve mt7620 built-in wifi performance some changes:
1. Correct BW20/BW40 switching (see comments with mark see commets with mark (1))
2. Correct TX_SW_CFG1 MAC reg from v3 of vendor driver see
        https://gitlab.com/dm38/padavan-ng/-/blob/master/trunk/proprietary/rt_wifi/rtpci/3.0.X.X/mt76x2/chips/rt6352.c#L531
3. Set bbp66 for all chains.
4. US_CYC_CNT init based on Programming guide, default value was 33 (pci),
   set chipset bus clock with fallback to cpu clock/3.
5. Don't overwrite default values for mt7620.
6. Correct some typos.
7. Add support for external LNA:
    a) RF and BBP regs never be corrected for this mode
    b) eLNA is driven the same way as ePA with mt7620's pin PA
        but vendor driver explicitly pin PA to gpio mode (for forrect calibration?)
        so I'm not sure that request for pa_pin in dts-file will be enough

First 5 changes (really 2) improve performance for boards w/o eLNA/ePA.
Changes 7 add support for eLNA

Configuration w/o eLAN/ePA and with eLNA show results
tx/rx (from router point of view) for each stream:
 35-40/30-35 Mbps for HT20
 65-70/60-65 Mbps for HT40

Yes. Max results for 2T2R client is 140-145/135-140
with peaks 160/150, It correspond to mediatek driver results.
Boards with ePA untested.

Reported-by: Serge Vasilugin <vasilugin@yandex.ru>
Signed-off-by: Daniel Golle <daniel@makrotopia.org>
---
--- a/drivers/net/wireless/ralink/rt2x00/rt2800lib.c
+++ b/drivers/net/wireless/ralink/rt2x00/rt2800lib.c
@@ -137,6 +137,26 @@ static u8 rt2800_bbp_read(struct rt2x00_
 
 	return value;
 }
+//serge: move here for use in test
+static void rt2800_bbp_glrt_write(struct rt2x00_dev *rt2x00dev,
+				  const u8 reg, const u8 value)
+{
+	rt2800_bbp_write(rt2x00dev, 195, reg);
+	rt2800_bbp_write(rt2x00dev, 196, value);
+}
+
+static void rt2800_bbp_dcoc_write(struct rt2x00_dev *rt2x00dev,
+				  const u8 reg, const u8 value)
+{
+	rt2800_bbp_write(rt2x00dev, 158, reg);
+	rt2800_bbp_write(rt2x00dev, 159, value);
+}
+
+static u8 rt2800_bbp_dcoc_read(struct rt2x00_dev *rt2x00dev, const u8 reg)
+{
+	rt2800_bbp_write(rt2x00dev, 158, reg);
+	return rt2800_bbp_read(rt2x00dev, 159);
+}
 
 static void rt2800_rfcsr_write(struct rt2x00_dev *rt2x00dev,
 			       const unsigned int word, const u8 value)
@@ -284,6 +304,28 @@ static void rt2800_rf_write(struct rt2x0
 	mutex_unlock(&rt2x00dev->csr_mutex);
 }
 
+void rt6352_enable_pa_pin(struct rt2x00_dev *rt2x00dev, int enable)
+{
+	if (!rt2x00dev->pinctrl)
+		return;
+
+	if (enable) {
+		if (!rt2x00dev->pins_default) {
+			rt2x00_warn(rt2x00dev, "cannot enable PA pin! no default pinctrl\n");
+			return;
+		}
+
+		pinctrl_select_state(rt2x00dev->pinctrl, rt2x00dev->pins_default);
+	} else {
+		if (!rt2x00dev->pins_pa_gpio) {
+			rt2x00_warn(rt2x00dev, "cannot disable PA pin! no pa_gpio pinctrl\n");
+			return;
+		}
+
+		pinctrl_select_state(rt2x00dev->pinctrl, rt2x00dev->pins_pa_gpio);
+	}
+}
+
 static const unsigned int rt2800_eeprom_map[EEPROM_WORD_COUNT] = {
 	[EEPROM_CHIP_ID]		= 0x0000,
 	[EEPROM_VERSION]		= 0x0001,
@@ -3801,6 +3843,20 @@ static void rt2800_config_channel_rf7620
 		rfcsr |= tx_agc_fc;
 		rt2800_rfcsr_write_bank(rt2x00dev, 7, 59, rfcsr);
 	}
+
+	if (conf_is_ht40(conf)) {//serge:skipped this step (1)
+		rt2800_bbp_write(rt2x00dev, 195, 141);
+		rt2800_bbp_write(rt2x00dev, 196, 0x10);
+		rt2800_bbp_write(rt2x00dev, 195, 157);
+		rt2800_bbp_write(rt2x00dev, 196, 0x2f);
+		//rt2800_bbp_write(rt2x00dev, 105, 0x3C);
+	} else {
+		rt2800_bbp_write(rt2x00dev, 195, 141);
+		rt2800_bbp_write(rt2x00dev, 196, 0x1a);
+		rt2800_bbp_write(rt2x00dev, 195, 157);
+		rt2800_bbp_write(rt2x00dev, 196, 0x40);
+		//rt2800_bbp_write(rt2x00dev, 105, 0x1C);
+	}
 }
 
 static void rt2800_config_alc(struct rt2x00_dev *rt2x00dev,
@@ -4172,6 +4228,11 @@ static void rt2800_config_channel(struct
 			rt2800_bbp_write(rt2x00dev, 86, 0x46);
 		else
 			rt2800_bbp_write(rt2x00dev, 86, 0);
+	} else if (rt2x00_rt(rt2x00dev, RT6352)) {//serge: don't overwite bbp r86 (5)
+		rt2800_bbp_write(rt2x00dev, 62, 0x37 - rt2x00dev->lna_gain);
+		rt2800_bbp_write(rt2x00dev, 63, 0x37 - rt2x00dev->lna_gain);
+		rt2800_bbp_write(rt2x00dev, 64, 0x37 - rt2x00dev->lna_gain);
+		rt2800_bbp_write(rt2x00dev, 86, 0x38);
 	} else {
 		rt2800_bbp_write(rt2x00dev, 62, 0x37 - rt2x00dev->lna_gain);
 		rt2800_bbp_write(rt2x00dev, 63, 0x37 - rt2x00dev->lna_gain);
@@ -4377,7 +4438,8 @@ static void rt2800_config_channel(struct
 		reg = (rf->channel <= 14 ? 0x1c : 0x24) + 2*rt2x00dev->lna_gain;
 		rt2800_bbp_write_with_rx_chain(rt2x00dev, 66, reg);
 
-		rt2800_iq_calibrate(rt2x00dev, rf->channel);
+		if (!rt2x00_rt(rt2x00dev, RT6352))//serge: this function for rt5592 only, for rt6352 it switch off compensations (5)
+		    rt2800_iq_calibrate(rt2x00dev, rf->channel);
 	}
 
 	if (rt2x00_rt(rt2x00dev, RT6352)) {
@@ -4417,6 +4479,31 @@ static void rt2800_config_channel(struct
 			rt2800_register_write(rt2x00dev, TX1_RF_GAIN_ATTEN,
 					      0x6C6C6B6C);
 		}
+
+		if (rt2x00_has_cap_external_lna_bg(rt2x00dev)) {//serge: for support eLNA (7a)
+			rt2x00_warn(rt2x00dev, "Correct RF/BBP for eLNA!\n");
+			reg = rt2800_register_read(rt2x00dev, RF_CONTROL3);
+			reg |= 0x00000101;
+			rt2800_register_write(rt2x00dev, RF_CONTROL3, reg);
+
+			reg = rt2800_register_read(rt2x00dev, RF_BYPASS3);
+			reg |= 0x00000101;
+			rt2800_register_write(rt2x00dev, RF_BYPASS3, reg);
+
+			rt2800_rfcsr_write_chanreg(rt2x00dev, 14, 0x66);
+			rt2800_rfcsr_write_chanreg(rt2x00dev, 17, 0x20);
+			rt2800_rfcsr_write_chanreg(rt2x00dev, 18, 0x42);
+			rt2800_bbp_write(rt2x00dev, 75, 0x68);//serge: move bbp eLNA init here?
+			rt2800_bbp_write(rt2x00dev, 76, 0x4C);
+			rt2800_bbp_write(rt2x00dev, 79, 0x1C);
+			rt2800_bbp_write(rt2x00dev, 80, 0x0C);
+			rt2800_bbp_write(rt2x00dev, 82, 0xB6);
+			/* bank 0 RF reg 42 and glrt BBP reg 141
+			will be set in config channel function
+			in dependence of channel and HT20/HT40
+			so don't touch it
+			*/
+		}
 	}
 
 	bbp = rt2800_bbp_read(rt2x00dev, 4);
@@ -4457,6 +4544,9 @@ static void rt2800_config_channel(struct
 		rt2x00_set_field8(&bbp, BBP49_UPDATE_FLAG, 0);
 		rt2800_bbp_write(rt2x00dev, 49, bbp);
 	}
+//serge:just print results after config channel - don't forget to remove nahren (c) <- this is copyright, not ref to comments :)
+	bbp = rt2800_bbp_dcoc_read(rt2x00dev, 0x03);
+	pr_info("BBP tx/rx compensation control=0x%02x\n", bbp);
 }
 
 static int rt2800_get_gain_calibration_delta(struct rt2x00_dev *rt2x00dev)
@@ -5527,7 +5617,7 @@ void rt2800_vco_calibration(struct rt2x0
 	}
 	rt2800_register_write(rt2x00dev, TX_PIN_CFG, tx_pin);
 
-	if (rt2x00_rt(rt2x00dev, RT6352)) {
+	if (rt2x00_rt(rt2x00dev, RT6352)) {//serge:remark - move all this code to rfcsr_6352 init?
 		if (rt2x00dev->default_ant.rx_chain_num == 1) {
 			rt2800_bbp_write(rt2x00dev, 91, 0x07);
 			rt2800_bbp_write(rt2x00dev, 95, 0x1A);
@@ -5695,7 +5785,8 @@ static inline void rt2800_set_vgc(struct
 	if (qual->vgc_level != vgc_level) {
 		if (rt2x00_rt(rt2x00dev, RT3572) ||
 		    rt2x00_rt(rt2x00dev, RT3593) ||
-		    rt2x00_rt(rt2x00dev, RT3883)) {
+		    rt2x00_rt(rt2x00dev, RT3883) ||
+		    rt2x00_rt(rt2x00dev, RT6352)) {//serge: rt6352 too (3)
 			rt2800_bbp_write_with_rx_chain(rt2x00dev, 66,
 						       vgc_level);
 		} else if (rt2x00_rt(rt2x00dev, RT5592)) {
@@ -5930,7 +6021,7 @@ static int rt2800_init_registers(struct
 					      0x00550055);
 		} else {
 			rt2800_register_write(rt2x00dev, TX_SW_CFG0, 0x00000401);
-			rt2800_register_write(rt2x00dev, TX_SW_CFG1, 0x000C0000);
+			rt2800_register_write(rt2x00dev, TX_SW_CFG1, 0x000C0001);//serge:was 0x000C0000 (2)
 			rt2800_register_write(rt2x00dev, TX_SW_CFG2, 0x00000000);
 			rt2800_register_write(rt2x00dev, TX_ALC_VGA3, 0x00000000);
 			rt2800_register_write(rt2x00dev, TX0_BB_GAIN_ATTEN, 0x0);
@@ -6195,6 +6286,29 @@ static int rt2800_init_registers(struct
 		reg = rt2800_register_read(rt2x00dev, US_CYC_CNT);
 		rt2x00_set_field32(&reg, US_CYC_CNT_CLOCK_CYCLE, 125);
 		rt2800_register_write(rt2x00dev, US_CYC_CNT, reg);
+	} else if (rt2x00_is_soc(rt2x00dev)) {//serge:which value correct? (4)
+		struct clk *clk = clk_get_sys("bus", NULL);
+		int rate;
+
+		if (IS_ERR(clk)) {
+			rt2x00_warn(rt2x00dev, "system bus clock undefined\n");
+			clk = clk_get_sys("cpu", NULL);
+
+			if (IS_ERR(clk))
+			    rate = 125;
+			else {
+			    rate = clk_get_rate(clk) / 3000000;
+			    clk_put(clk);
+			}
+		} else {
+			rate = clk_get_rate(clk) / 1000000;
+			clk_put(clk);
+		}
+
+		rt2x00_info(rt2x00dev, "set US_CYC=%dMHz\n", rate);
+		reg = rt2800_register_read(rt2x00dev, US_CYC_CNT);
+		rt2x00_set_field32(&reg, US_CYC_CNT_CLOCK_CYCLE, rate);
+		rt2800_register_write(rt2x00dev, US_CYC_CNT, reg);
 	}
 
 	reg = rt2800_register_read(rt2x00dev, HT_FBK_CFG0);
@@ -6981,26 +7095,7 @@ static void rt2800_init_bbp_5592(struct
 	if (rt2x00_rt_rev_gte(rt2x00dev, RT5592, REV_RT5592C))
 		rt2800_bbp_write(rt2x00dev, 103, 0xc0);
 }
-
-static void rt2800_bbp_glrt_write(struct rt2x00_dev *rt2x00dev,
-				  const u8 reg, const u8 value)
-{
-	rt2800_bbp_write(rt2x00dev, 195, reg);
-	rt2800_bbp_write(rt2x00dev, 196, value);
-}
-
-static void rt2800_bbp_dcoc_write(struct rt2x00_dev *rt2x00dev,
-				  const u8 reg, const u8 value)
-{
-	rt2800_bbp_write(rt2x00dev, 158, reg);
-	rt2800_bbp_write(rt2x00dev, 159, value);
-}
-
-static u8 rt2800_bbp_dcoc_read(struct rt2x00_dev *rt2x00dev, const u8 reg)
-{
-	rt2800_bbp_write(rt2x00dev, 158, reg);
-	return rt2800_bbp_read(rt2x00dev, 159);
-}
+//serge: move these function upper
 
 static void rt2800_init_bbp_6352(struct rt2x00_dev *rt2x00dev)
 {
@@ -8635,7 +8730,7 @@ static void rt2800_r_calibration(struct
 		r_cal_code = (u8)rcalcode;
 
 	rt2800_rfcsr_write_bank(rt2x00dev, 0, 7, r_cal_code);
-
+	pr_info("RF bank 0 reg 5=0x%02x\n", r_cal_code);//serge: just for info to compare with vendor driver
 	rt2800_bbp_write(rt2x00dev, 22, 0x0);
 
 	bytevalue = rt2800_bbp_read(rt2x00dev, 21);
@@ -8693,7 +8788,7 @@ static void rt2800_rxdcoc_calibration(st
 			break;
 	}
 
-	saverfb5r4 = rt2800_rfcsr_read_bank(rt2x00dev, 5, 0);
+	saverfb5r4 = rt2800_rfcsr_read_bank(rt2x00dev, 5, 4);//serge: was 0 - typo? (6)
 	saverfb7r4 = rt2800_rfcsr_read_bank(rt2x00dev, 7, 4);
 	saverfb5r4 = saverfb5r4 & (~0x40);
 	saverfb7r4 = saverfb7r4 & (~0x40);
@@ -9022,13 +9117,15 @@ static void rt2800_rxiq_calibration(stru
 				rt2x00_info(rt2x00dev, "RXIQ G_imb=%d, Ph_rx=%d\n", g_imb, ph_rx);
 
 				if ((ph_rx > 20) || (ph_rx < -20)) {
+					rt2x00_warn(rt2x00dev, "RXIQ calibration FAIL(ph_rx=%d out of [-20..20]", ph_rx);//serge:just to see value
 					ph_rx = 0;
-					rt2x00_warn(rt2x00dev, "RXIQ calibration FAIL");
+					//rt2x00_warn(rt2x00dev, "RXIQ calibration FAIL");
 				}
 
 				if ((g_imb > 12) || (g_imb < -12)) {
+					rt2x00_warn(rt2x00dev, "RXIQ calibration FAIL(g_imb=%d out of (-12..12]", g_imb);//serge:just to see the reason
 					g_imb = 0;
-					rt2x00_warn(rt2x00dev, "RXIQ calibration FAIL");
+					//rt2x00_warn(rt2x00dev, "RXIQ calibration FAIL");
 				}
 			}
 		else {
@@ -9039,11 +9136,21 @@ static void rt2800_rxiq_calibration(stru
 		}
 
 		if (ch_idx == 0) {
+			//serge: just to see values
+			pr_info("RXIQ RX0 g_imb (0x37, %2x) ph_rx (0x35, %2x)\n",
+			    g_imb & 0x3f,
+			    ph_rx & 0x3f
+			);
 			rt2800_bbp_write(rt2x00dev, 158, 0x37);
 			rt2800_bbp_write(rt2x00dev, 159, g_imb & 0x3f);
 			rt2800_bbp_write(rt2x00dev, 158, 0x35);
 			rt2800_bbp_write(rt2x00dev, 159, ph_rx & 0x3f);
 		} else {
+			//serge: just to see values
+			pr_info("RXIQ RX1 g_imb (0x55, %2x) ph_rx (0x53, %2x)\n",
+			    g_imb & 0x3f,
+			    ph_rx & 0x3f
+			);
 			rt2800_bbp_write(rt2x00dev, 158, 0x55);
 			rt2800_bbp_write(rt2x00dev, 159, g_imb & 0x3f);
 			rt2800_bbp_write(rt2x00dev, 158, 0x53);
@@ -9745,6 +9852,15 @@ void rt2800_loft_iq_calibration(struct r
 	}
 
 	for (rf_alc_idx = 0; rf_alc_idx < 3; rf_alc_idx++) {
+		//serge: just to see values
+		pr_info("LOFT ALC (0xb0, %2x) I0 (0xb1, %2x) Q0 (0xb2, %2x) I1 (0xb8, %2x) Q1 (0xb9, %2x)\n",
+		    rf_alc_idx,
+		    loft_dc_search_result[CHAIN_0][rf_alc_idx][0x00] & 0x3F,
+		    loft_dc_search_result[CHAIN_0][rf_alc_idx][0x01] & 0x3F,
+		    loft_dc_search_result[CHAIN_1][rf_alc_idx][0x00] & 0x3F,
+		    loft_dc_search_result[CHAIN_1][rf_alc_idx][0x01] & 0x3F
+		);
+
 		for (idx = 0; idx < 4; idx++) {
 			rt2800_bbp_write(rt2x00dev, 158, 0xB0);
 			bbp = (idx<<2) + rf_alc_idx;
@@ -10669,6 +10785,7 @@ static void rt2800_init_rfcsr_6352(struc
 		rt2800_rfcsr_write_dccal(rt2x00dev, 17, 0x7C);
 	}
 
+	rt6352_enable_pa_pin(rt2x00dev, 0);//serge: vendor driver do it before calibration (7b)
 	rt2800_r_calibration(rt2x00dev);
 	rt2800_rf_self_txdc_cal(rt2x00dev);
 	rt2800_rxdcoc_calibration(rt2x00dev);
@@ -10676,6 +10793,29 @@ static void rt2800_init_rfcsr_6352(struc
 	rt2800_bw_filter_calibration(rt2x00dev, false);
 	rt2800_loft_iq_calibration(rt2x00dev);
 	rt2800_rxiq_calibration(rt2x00dev);
+	rt6352_enable_pa_pin(rt2x00dev, 1);//serge: vendor driver do it after calibration (7b)
+	/* Vendor driver restore iLNA/iPA before
+	recalibration and set correct values after.
+	Openwrt driver init iLNA and iPA but restore only
+	ePA values after recalibration.
+	So set eLNA values only
+	*/
+	if (rt2x00_has_cap_external_lna_bg(rt2x00dev)) {//serge: rf regs never corrected for eLNA (7a)
+		rt2x00_info(rt2x00dev, "Correct RF/BBP for eLNA!\n");
+		rt2800_rfcsr_write_chanreg(rt2x00dev, 14, 0x66);
+		rt2800_rfcsr_write_chanreg(rt2x00dev, 17, 0x20);
+		rt2800_rfcsr_write_chanreg(rt2x00dev, 18, 0x42);
+		rt2800_bbp_write(rt2x00dev, 75, 0x68);//serge: move bbp eLNA init here?
+		rt2800_bbp_write(rt2x00dev, 76, 0x4C);
+		rt2800_bbp_write(rt2x00dev, 79, 0x1C);
+		rt2800_bbp_write(rt2x00dev, 80, 0x0C);
+		rt2800_bbp_write(rt2x00dev, 82, 0xB6);
+		/* bank 0 RF reg 42 and glrt BBP reg 141
+		will be set in config channel function
+		in dependence of channel and HT20/HT40
+		so don't touch it
+		*/
+	}
 }
 
 static void rt2800_init_rfcsr(struct rt2x00_dev *rt2x00dev)
--- a/drivers/net/wireless/ralink/rt2x00/rt2x00.h
+++ b/drivers/net/wireless/ralink/rt2x00/rt2x00.h
@@ -28,6 +28,7 @@
 #include <linux/average.h>
 #include <linux/usb.h>
 #include <linux/clk.h>
+#include <linux/pinctrl/consumer.h>
 #include <linux/rt2x00_platform.h>
 
 #include <net/mac80211.h>
@@ -1029,6 +1030,11 @@ struct rt2x00_dev {
 
 	/* Clock for System On Chip devices. */
 	struct clk *clk;
+
+	/* pinctrl and states for System On Chip devices with PA/LNA. */
+	struct pinctrl *pinctrl;
+	struct pinctrl_state *pins_default;
+	struct pinctrl_state *pins_pa_gpio;
 };
 
 struct rt2x00_bar_list_entry {
--- a/drivers/net/wireless/ralink/rt2x00/rt2x00soc.c
+++ b/drivers/net/wireless/ralink/rt2x00/rt2x00soc.c
@@ -97,6 +97,21 @@ int rt2x00soc_probe(struct platform_devi
 	if (retval)
 		goto exit_free_reg;
 
+	rt2x00dev->pinctrl = devm_pinctrl_get(&pdev->dev);
+	if (IS_ERR(rt2x00dev->pinctrl)) {
+		rt2x00dev->pinctrl = NULL;
+		rt2x00dev->pins_default = NULL;
+		rt2x00dev->pins_pa_gpio = NULL;
+	} else {
+		rt2x00dev->pins_default = pinctrl_lookup_state(rt2x00dev->pinctrl, "default");
+		if (IS_ERR(rt2x00dev->pins_default))
+			rt2x00dev->pins_default = NULL;
+
+		rt2x00dev->pins_pa_gpio = pinctrl_lookup_state(rt2x00dev->pinctrl, "pa_gpio");
+		if (IS_ERR(rt2x00dev->pins_pa_gpio))
+			rt2x00dev->pins_pa_gpio = NULL;
+	}
+
 	return 0;
 
 exit_free_reg:

P992
echo "==> v18 rt2x00 补丁已写入 $(wc -l < "$SRC/target/linux/ramips/patches-5.15/992-rt2x00-more-fixes.patch") 行"









