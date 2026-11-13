#!/bin/bash
# 连乐2 / 乐视 LBA-047-CH  —— 官方 OKLI 布局 + 定制包 + 全口LAN + 默认开WiFi
# 布局：0x50000 = OKLI 内核+文件系统；0xE80000 = 64K loader（官方原厂方式）
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

# ---------- 1. 屏蔽旧的 diy-part2.sh ----------
# 它会在之后覆盖 files/etc/rc.local，还会把默认IP改成 192.168.2.1
cat > "$WS/diy-part2.sh" << 'EOS'
#!/bin/bash
exit 0
EOS
chmod +x "$WS/diy-part2.sh"

# ---------- 2. .config 补必需包（这份随后会被 workflow 移进 openwrt/.config） ----------
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
add_cfg CONFIG_PACKAGE_openssh-sftp-server
# 清掉 23.05 不存在的假包名
sed -i '/CONFIG_PACKAGE_luci-network=y/d; /CONFIG_PACKAGE_luci-system=y/d' "$CFG" 2>/dev/null || true
echo "==> .config 已补包"

# ---------- 3. 设备定义：照官方 letv 的 OKLI 方案，设备名仍叫 lelink_le2 ----------
GMK="$SRC/target/linux/ath79/image/generic.mk"
if grep -q "^define Device/lelink_le2$" "$GMK"; then
	sed -i '/^define Device\/lelink_le2$/,/^TARGET_DEVICES += lelink_le2$/d' "$GMK"
fi
cat >> "$GMK" << 'EOF'

# 连乐2：沿用上游乐视 LBA-047-CH 的 DTS 与 OKLI 引导方案
# 0x50000 = OKLI 内核+文件系统；0xE80000 = 64K loader
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
echo "==> OKLI 设备定义已写入（loader 落在 0xE80000）"

# ---------- 4. 兜底：网口都进 LAN + 默认开 WiFi ----------
mkdir -p "$SRC/files/etc/uci-defaults"
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

cat > "$SRC/files/etc/rc.local" << 'EOF'
#!/bin/sh
sleep 8
# 把 eth0 也并进 br-lan：插哪个网口都能打开后台
ip link set eth0 master br-lan 2>/dev/null || brctl addif br-lan eth0 2>/dev/null
# 强制开一个开放热点
[ -f /etc/config/wireless ] || wifi config >/dev/null 2>&1
if [ -f /etc/config/wireless ]; then
	uci -q set wireless.radio0.disabled='0' || true
	uci -q set wireless.@wifi-iface[0].disabled='0' || true
	uci -q set wireless.@wifi-iface[0].ssid='OpenWrt' || true
	uci -q set wireless.@wifi-iface[0].encryption='none' || true
	uci -q set wireless.@wifi-iface[0].network='lan' || true
	uci -q commit wireless
	wifi up 2>/dev/null
fi
exit 0
EOF
chmod +x "$SRC/files/etc/rc.local"
echo "==> files/etc/rc.local 与 uci-defaults 已写入"

# ---------- 5. 自检 ----------
echo "---- .config 关键项 ----"
grep -E 'DEVICE_lelink_le2|PACKAGE_wpad|PACKAGE_aircrack|PACKAGE_kmod-ath9k' "$CFG" || true
echo "---- 设备定义 ----"
grep -A 14 'define Device/lelink_le2' "$GMK"
echo "==> 完成"
