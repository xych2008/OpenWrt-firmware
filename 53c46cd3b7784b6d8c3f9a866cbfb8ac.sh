#!/bin/bash
# diy-part1.sh（Breed 版）— 底子：乐视 LBA-047-CH（letv_lba-047-ch，QCA9531 / 16MB）
#
# 说明：你现在那份 DTS 就是把上游 qca9531_letv_lba-047-ch.dts 逐字抄过来的（art@0xff0000、
# calibration@0x1000、eth0 phy-handle=&swphy4、eth1 nvmem 全一样），只是改了 compatible/model。
# 但上游 letv_lba-047-ch 这个 profile 是给【原厂 uboot + OKLI loader 链】用的：
#   $(Device/loader-okli-uimage) / KERNEL magic 0x4f4b4c49 / factory 尾部追加 64k loader / FACTORY_SIZE 14528k
# Breed 不是原厂 uboot，它不会去跳 loader 分区，也不认 OKLI magic —— 所以照它打底，刷完必回 Breed。
#
# 下面保留乐视的 flash 布局，只把"引导方式"改成 Breed 能吃的：标准 uImage + 连续 firmware 分区。
#
# ┌─ 需要你核对 Breed「分区表」后改这两个值 ─────────────────────────────┐
# │ 情形 A：Breed 里 firmware 是整段 0x50000~0xFF0000 (16000k)          │
# │        FW_SIZE=0xfa0000      IMAGE_SIZE=15872k                      │
# │ 情形 B：Breed 保留乐视原厂分表（0xE80000 处有 loader 分区）          │
# │        firmware 只能到 0xE80000 → FW_SIZE=0xe30000  IMAGE_SIZE=14464k│
# └──────────────────────────────────────────────────────────────────┘
FW_SIZE=0xfa0000
IMAGE_SIZE=15872k

echo "=====写入连乐2 DTS（Breed 兼容：标准 uImage + 单一 firmware 分区）====="
cat > target/linux/ath79/dts/qca9531_lelink_le2.dts << DTS_EOF
// SPDX-License-Identifier: GPL-2.0-or-later OR MIT
/dts-v1/;
#include "qca953x.dtsi"
#include <dt-bindings/gpio/gpio.h>
#include <dt-bindings/input/input.h>
#include <dt-bindings/leds/common.h>

/ {
	compatible = "lelink,le2", "qca,qca9531";
	model = "Lelink LE2";

	aliases {
		label-mac-device = &eth0;
		led-boot = &led_status_red;
		led-failsafe = &led_status_blue;
		led-running = &led_status_green;
		led-upgrade = &led_status_blue;
	};

	keys {
		compatible = "gpio-keys";

		reset {
			label = "reset";
			linux,code = <KEY_RESTART>;
			/* 上游乐视 LBA-047-CH 实测：复位键 GPIO17 低有效 */
			gpios = <&gpio 17 GPIO_ACTIVE_LOW>;
		};
	};

	leds {
		compatible = "gpio-leds";

		led_status_blue: led-0 {
			label = "blue:status";
			color = <LED_COLOR_ID_BLUE>;
			function = LED_FUNCTION_STATUS;
			gpios = <&gpio 13 GPIO_ACTIVE_LOW>;
		};

		led_status_green: led-1 {
			label = "green:status";
			color = <LED_COLOR_ID_GREEN>;
			function = LED_FUNCTION_STATUS;
			gpios = <&gpio 4 GPIO_ACTIVE_LOW>;
		};

		led_status_red: led-2 {
			label = "red:status";
			color = <LED_COLOR_ID_RED>;
			function = LED_FUNCTION_STATUS;
			gpios = <&gpio 11 GPIO_ACTIVE_LOW>;
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
			partition@50000 {
				label = "firmware";
				reg = <0x50000 ${FW_SIZE}>;
				compatible = "denx,uimage";
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
	phy-handle = <&swphy4>;
};

&eth1 {
	compatible = "qca,qca9530-eth", "syscon", "simple-mfd";
	nvmem-cells = <&macaddr_art_6>;
	nvmem-cell-names = "mac-address";
};

&wmac {
	status = "okay";
	nvmem-cells = <&cal_art_1000>;
	nvmem-cell-names = "calibration";
};
DTS_EOF

echo "=====追加设备定义（标准 uImage，不使用 loader-okli / 不设 OKLI magic）====="
cat >> target/linux/ath79/image/generic.mk << MK_EOF

define Device/lelink_le2
  SOC := qca9531
  DEVICE_VENDOR := Lelink
  DEVICE_MODEL := LE2
  DEVICE_PACKAGES := -uboot-envtools
  IMAGE_SIZE := ${IMAGE_SIZE}
  IMAGES := sysupgrade.bin factory.bin
  # factory.bin 是纯 kernel+rootfs，Breed 里刷它；进了 LuCI 再用 sysupgrade.bin 升级
  IMAGE/factory.bin := append-kernel | pad-to 64k | \\
	append-rootfs | pad-rootfs | check-size
endef
TARGET_DEVICES += lelink_le2
MK_EOF

echo "=====打 02_network 补丁（两个 MAC 都进 LAN）====="
BOARD_FILE=target/linux/ath79/generic/base-files/etc/board.d/02_network
# 原版两处必错：1) 上游是 "\tesac"（带 Tab），/^esac$/ 匹配不到；
#                2) 就算匹配到，插在 "*) 兜底" 之后也永远轮不到（case 顺序匹配）。
# 正确做法：插到第一个 "\t*)" 之前，只插一次。
awk 'BEGIN{ins=0} /^\t\*)/{if(!ins){
  print "\tlelink,le2)"
  print "\t\tucidef_set_interface_wan \"eth0\""
  print "\t\tucidef_add_switch \"switch0\" \\"
  print "\t\t\t\"0@eth1\" \"3:lan:2\" \"4:lan:1\""
  print "\t\t;;"
  ins=1}} {print}' "$BOARD_FILE" > "$BOARD_FILE.tmp" && mv "$BOARD_FILE.tmp" "$BOARD_FILE"

# 自检：补丁没进去就让构建直接失败，别再编出"哑巴固件"
grep -q 'lelink,le2)' "$BOARD_FILE" || { echo "ERROR: 02_network 补丁未生效"; exit 1; }
sed -n '/lelink,le2)/,+3p' "$BOARD_FILE"
