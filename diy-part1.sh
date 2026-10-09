#!/bin/bash
# diy-part1.sh：云端适配 lelink_le2 设备树（OKLI/mtd-concat）+ OKLI 链 + 02_network
# 适配 Lelink LE2 / QCA9531 / 16MB / NVMEM 校准 / SPI 30MHz+fast-read
echo "=====写入连乐2 QCA9531 DTS设备树====="
cat > target/linux/ath79/dts/qca9531_lelink_le2.dts << 'DTS_EOF'
// SPDX-License-Identifier: GPL-2.0-or-later OR MIT
/dts-v1/;
#include "qca953x.dtsi"
#include <dt-bindings/mtd/partitions/uimage.h>

/ {
	compatible = "lelink,le2", "qca,qca9531";
	model = "Lelink LE2";
	aliases {
		label-mac-device = &eth0;
	};

	virtual_flash {
		compatible = "mtd-concat";
		devices = <&fwconcat0 &fwconcat1>;

		partitions {
			compatible = "fixed-partitions";
			#address-cells = <1>;
			#size-cells = <1>;

			partition@0 {
				reg = <0x0 0x0>;
				label = "firmware";
				compatible = "openwrt,uimage", "denx,uimage";
				openwrt,ih-magic = <IH_MAGIC_OKLI>;
			};
		};
	};
};

&spi {
	status = "okay";
	flash@0 {
		compatible = "jedec,spi-nor";
		reg = <0>;
		spi-max-frequency = <30000000>;
		m25p,fast-read;
		partitions {
			compatible = "fixed-partitions";
			#address-cells = <1>;
			#size-cells = <1>;
			partition@0 {
				label = "u-boot";
				reg = <0x0 0x40000>;
				read-only;
			};
			partition@40000 {
				label = "u-boot-env";
				reg = <0x40000 0x10000>;
				read-only;
			};
			fwconcat0: partition@50000 {
				label = "fwconcat0";
				reg = <0x50000 0xe30000>;
			};
			partition@e80000 {
				label = "loader";
				reg = <0xe80000 0x10000>;
			};
			fwconcat1: partition@e90000 {
				label = "fwconcat1";
				reg = <0xe90000 0x160000>;
			};
			art: partition@ff0000 {
				label = "art";
				reg = <0xff0000 0x10000>;
				read-only;
				compatible = "nvmem-cells";
				#address-cells = <1>;
				#size-cells = <1>;
				macaddr_art_0: macaddr@0 {
					reg = <0x0 0x6>;
				};
				macaddr_art_6: macaddr@6 {
					reg = <0x6 0x6>;
				};
				cal_art_1000: calibration@1000 {
					reg = <0x1000 0x440>;
				};
			};
		};
	};
};

&eth0 {
	status = "okay";
	nvmem-cells = <&macaddr_art_0>;
	nvmem-cell-names = "mac-address";
};

&eth1 {
	compatible = "qca,qca9530-eth", "syscon", "simple-mfd";
};

&wmac {
	status = "okay";
	nvmem-cells = <&cal_art_1000>;
	nvmem-cell-names = "calibration";
};
DTS_EOF

# 2) 在 ath79/generic.mk 追加设备定义（OKLI 链，与 run #6 逐字一致）
cat >> target/linux/ath79/image/generic.mk << 'MK_EOF'

define Device/lelink_le2
  $(Device/loader-okli-uimage)
  SOC := qca9531
  DEVICE_VENDOR := Lelink
  DEVICE_MODEL := LE2
  IMAGE_SIZE := 16000k
  LOADER_FLASH_OFFS := 0x50000
  KERNEL := kernel-bin | append-dtb | lzma | uImage lzma -M 0x4f4b4c49
  IMAGES := sysupgrade.bin factory.bin
  IMAGE/factory.bin := append-kernel | pad-to $$$$(BLOCKSIZE) | \
	append-rootfs | pad-rootfs | check-size | pad-to 14528k | \
	append-loader-okli-uimage $(1) | pad-to 64k
endef
TARGET_DEVICES += lelink_le2
MK_EOF

# 3) 02_network（LAN=lan1 lan2，WAN=eth0，MAC 从 art 0x0 取）
BOARD_FILE=target/linux/ath79/generic/base-files/etc/board.d/02_network
awk 'BEGIN{ins=0} /^esac$/{if(!ins){print "lelink,le2)"; print "\tucidef_set_interfaces_lan_wan \"lan1 lan2\" \"wan\""; print "\tucidef_set_interface_macaddr \"wan\" \"$(mtd_get_mac_binary art 0x0)\""; print "\t;;"; ins=1}} {print}' "$BOARD_FILE" > "$BOARD_FILE.tmp" && mv "$BOARD_FILE.tmp" "$BOARD_FILE"
