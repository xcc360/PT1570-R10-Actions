// SPDX-License-Identifier: GPL-2.0+
/*
 * Youhua PT1570-H10-CU (Unicom) 2.5G board description — full status lamps.
 *
 * Why this file exists
 * --------------------
 * The upstream board/youhua/pt1570-h10-ct/desc-2p5g.c lists only four LAN
 * lamps on pins 0/1/3/4, all active-low — that is the *4GE* lamp map
 * (compare board/tianyi/tyfza1/desc-4ge.c: pins 4/3/1/0, active-low).
 * The real 2.5G lamp map is board/tianyi/tyfza1/desc-2p5g.c:
 *     pins 11/12 active-high, pins 3/4 active-low,
 * which matches the OpenWrt DTS override in
 * target/linux/rtl9617c/dts/rtl9617c-tyfza1-2p5g.dts:
 *     lan0 = <&gpio0 11 GPIO_ACTIVE_HIGH>, lan1 = <&gpio0 12 ...HIGH>,
 *     lan2 = <&gpio0 3  GPIO_ACTIVE_LOW>,  lan3 = <&gpio0 4  ...LOW>.
 *
 * On this Unicom unit the CT desc produced exactly three lit GE lamps
 * (reported 2026-11-14), i.e. pins 0/1/3 are real LAN lamps and pin 4 is not
 * — the panel wiring follows the Youhua PT15x0-H10 family (same as
 * PT1500-H10-CT), whose already-verified desc is
 * board/youhua/pt1500-h10-ct/desc-2p5g.c with ten lamps:
 *     power 11, pon 9, los 10, ppp 2, fxs 12, usb0 7, lan 0/1/3, usb1 6.
 *
 * Rather than guess which of the two maps this particular panel uses, this
 * desc lists the UNION of both, in PT1500 panel order. Every shared pin has
 * the SAME polarity in both maps (verified pairwise below), so no lamp can be
 * driven inverted regardless of which wiring is on the board:
 *
 *   pin  PT1500/4GE dtsi          2p5g DTS override        polarity
 *   ---  -----------------------  -----------------------  ---------
 *     0  lan3 LED_EPHY3 (low)     unused                   low
 *     1  lan2 LED_EPHY2 (low)     unused                   low
 *     2  ppp  LED_PPP_G (low)     usb1 LED_USB1 (low)      low   (both)
 *     3  lan1 LED_EPHY1 (low)     lan2 (low)               low   (both)
 *     4  lan0 LED_EPHY0 (low)     lan3 (low)               low   (both)
 *     7  usb0 LED_USB0 (high)     node deleted             high
 *     9  pon  LED_PON   (low)     pon  (low)               low   (both)
 *    10  los  LED_LOS   (low)     los  (low)               low   (both)
 *    11  power LED_PWR_G (high)   lan0 (high)              high  (both)
 *    12  fxs   LED_FXS   (high)   lan1 (high)              high  (both)
 *
 * Constraints from the failsafe framework (do not "simplify" this):
 *   * struct rtk_led.pin is a GLOBAL GPIO number (u8), not a bank bit.
 *   * rtl9617c_gpio_group_select() rejects a lamp set that spans more than
 *     one 32-pin bank; all ten pins here live in bank 0 (pin < 32).
 *   * Pin 8 is the reset key (active low) and MUST NOT be claimed as a lamp.
 *     Pin 5 (WPS) has no failsafe state upstream and stays with the OS;
 *     pin 6 (usb1) was commented out in the verified PT1500 desc. Both are
 *     deliberately left out.
 *   * Lamps are listed in front-panel order: rtk_board_boot_leds() sweeps
 *     them once at power-on, RTK_LEDS_IDLE runs a runner along them while the
 *     web failsafe waits, BUSY shows a progress bar, DONE holds all on for
 *     two seconds, FAILED alternates odd/even. Ten lamps make each state
 *     legible from across the room — which is the whole point: with the old
 *     four-lamp CT desc you could not tell "U-Boot alive" from "kernel hung".
 *   * The 2.5G jack's lamp is driven by its PHY, not by a GPIO, so it is not
 *     listed (upstream PT1500 desc says the same).
 *
 * Only this board description is replaced at build time; geometry, FIP UUIDs,
 * BL2/BL31 and the CU stock GPT are untouched by the lamp change.
 */
#include <config.h>
#include <linux/kernel.h>
#include <failsafe/desc.h>

static const struct rtk_led pt1570_h10_cu_2p5g_lamps[] = {
	{ .pin = 11 },				/* power  LED_PWR_G / 2p5g lan0 */
	{ .pin = 9,  .active_low = true },	/* pon    LED_PON */
	{ .pin = 10, .active_low = true },	/* los    LED_LOS */
	{ .pin = 2,  .active_low = true },	/* ppp    LED_PPP_G / 2p5g usb1 */
	{ .pin = 12 },				/* fxs    LED_FXS / 2p5g lan1 */
	{ .pin = 7 },				/* usb0   LED_USB0 */
	{ .pin = 0,  .active_low = true },	/* lan    LED_EPHY3 */
	{ .pin = 1,  .active_low = true },	/* lan    LED_EPHY2 */
	{ .pin = 3,  .active_low = true },	/* lan    LED_EPHY1 / 2p5g lan2 */
	{ .pin = 4,  .active_low = true },	/* lan    LED_EPHY0 / 2p5g lan3 */
};

static const struct rtk_board_variant pt1570_h10_cu_2p5g_variant = {
	.lamp = pt1570_h10_cu_2p5g_lamps,
	.nr_lamps = ARRAY_SIZE(pt1570_h10_cu_2p5g_lamps),
	.ports = "2.5GE + 3×GE",
};

static const struct rtk_board_desc pt1570_h10_cu_2p5g_desc = {
	.name = "Youhua PT1570-H10-CU",
	.version = "2026.07",
	.variant = &pt1570_h10_cu_2p5g_variant,
	.reset_pin = 8,
	.reset_active_low = true,
};

const struct rtk_board_desc *rtk_board_desc(void)
{
	return &pt1570_h10_cu_2p5g_desc;
}
