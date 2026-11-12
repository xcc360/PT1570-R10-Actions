// SPDX-License-Identifier: GPL-2.0+
/*
 * PT1570-R10 board description, read back from the OEM device tree
 * (rtk_gpio_led and gpio-keys). All twelve lamps sit on GPIO bank 0;
 * the third cell of led-gpio is 1 for active-low lamps.
 *
 *   LED_PWR_G  11  active high      LED_PON      9  active low
 *   LED_LOS    10  active low       LED_PPP_G    2  active low
 *   LED_FXS    12  active high      LED_USB0     7  active high
 *   LED_USB1    6  active low       LED_EPHY3    0  active low
 *   LED_EPHY2   1  active low       LED_EPHY1    3  active low
 *   LED_EPHY0   4  active low       LED_WPS_G    5  active high
 *
 * The reset key is bank 0 bit 8, active low. The OEM DTB also has
 * btn,led (KEY_... on bank 1 bit 7) and btn,wifi (bank 1 bit 3);
 * the failsafe descriptor only models a single reset key, so those two
 * stay with the OS.
 */
#include <config.h>
#include <linux/kernel.h>
#include <failsafe/desc.h>

static const struct rtk_led pt1570_r10_lamps[] = {
	{ .pin = 11 },				/* power, LED_PWR_G */
	{ .pin = 9,  .active_low = true },	/* pon, LED_PON */
	{ .pin = 10, .active_low = true },	/* los, LED_LOS */
	{ .pin = 2,  .active_low = true },	/* ppp, LED_PPP_G */
	{ .pin = 12 },				/* fxs, LED_FXS */
	{ .pin = 7 },				/* usb0, LED_USB0 */
	{ .pin = 6,  .active_low = true },	/* usb1, LED_USB1 */
	{ .pin = 0,  .active_low = true },	/* lan4, LED_EPHY3 */
	{ .pin = 1,  .active_low = true },	/* lan3, LED_EPHY2 */
	{ .pin = 3,  .active_low = true },	/* lan2, LED_EPHY1 */
	{ .pin = 4,  .active_low = true },	/* lan1, LED_EPHY0 */
	{ .pin = 5 },				/* wps, LED_WPS_G */
};

static const struct rtk_board_variant pt1570_r10_variant = {
	.lamp = pt1570_r10_lamps,
	.nr_lamps = ARRAY_SIZE(pt1570_r10_lamps),
	.ports = "4xGE (internal GPHY)",
};

static const struct rtk_board_desc pt1570_r10_desc = {
	.name = "PT1570-R10",
	.version = "2026.11",
	.variant = &pt1570_r10_variant,
	.reset_pin = 8,
	.reset_active_low = true,
};

const struct rtk_board_desc *rtk_board_desc(void)
{
	return &pt1570_r10_desc;
}
