#!/bin/bash
# 百米 HD51 v4：补 kmod-mt7620（v3 漏了它 → 板载 2.4G 从未起来 → 无 Wi-Fi 广播）
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

			partition@40000 {
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
	nvmem-cells = <&eeprom_factory_0>;
	nvmem-cell-names = "eeprom";
};

&pcie {
	status = "okay";
};
EOF
echo "==> DTS 已写入"

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
  DEVICE_PACKAGES := kmod-mt7620 kmod-mt76x0e kmod-mt76x2 kmod-usb2 kmod-usb-ohci \
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

cat > "$SRC/files/etc/uci-defaults/99-hd51-basic" << 'EOF'
#!/bin/sh
uci -q set system.@system[0].hostname='HD51' || true
uci -q set system.@system[0].timezone='CST-8' || true
uci -q set system.@system[0].zonename='Asia/Shanghai' || true
uci -q commit system

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
	uci -q set wireless.radio1.disabled='0' || true
	uci -q set wireless.radio1.country='CN' || true
	uci -q commit wireless
fi
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
run ip -br link
run ip -br addr

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
