#!/bin/bash
# diy-part1.sh：云端注入 lelink_le2 设备树 + 注册设备 + 网络配置
# 连乐2 Lelink LE2 / QCA9531 / 16MB / NVMEM 校准 / SPI 30MHz+fast-read / 单段四分区（无 OKLI）
echo "=====写入连乐2 QCA9531 DTS设备树====="
cat > target/linux/ath79/dts/qca9531_lelink_le2.dts << 'DTS_EOF'
// SPDX-License-Identifier: GPL-2.0-or-later OR MIT
/dts-v1/;

#include "qca953x.dtsi"

/ {
	compatible = "lelink,le2", "qca,qca9531";
	model = "Lelink LE2";

	aliases {
		label-mac-device = &eth0;
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

			partition@50000 {
				label = "firmware";
				reg = <0x50000 0xfa0000>;
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

# 2) 在 ath79/generic.mk 末尾注册设备（标准 uImage，无 OKLI）
cat >> target/linux/ath79/image/generic.mk << 'MK_EOF'

define Device/lelink_le2
  SOC := qca9531
  DEVICE_VENDOR := Lelink
  DEVICE_MODEL := LE2
  IMAGE_SIZE := 16000k
  IMAGES := sysupgrade.bin
endef
TARGET_DEVICES += lelink_le2
MK_EOF

# 3) 网络默认配置（LAN=2口走内置交换机，WAN=eth0）
BOARD_FILE=target/linux/ath79/generic/base-files/etc/board.d/02_network
awk 'BEGIN{ins=0} /^esac$/{if(!ins){print "lelink,le2)"; print "\tucidef_set_interfaces_lan_wan \"lan1 lan2\" \"wan\""; print "\tucidef_set_interface_macaddr \"wan\" \"$(mtd_get_mac_binary art 0x0)\""; print "\t;;"; ins=1}} {print}' "$BOARD_FILE" > "$BOARD_FILE.tmp" && mv "$BOARD_FILE.tmp" "$BOARD_FILE"
