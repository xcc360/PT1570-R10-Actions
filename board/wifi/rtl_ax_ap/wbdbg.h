/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef RTL_AX_WBDBG_H
#define RTL_AX_WBDBG_H
/* AP-start hard-lock localization markers. Always-on pr_emerg so the
 * last executed stage survives a watchdog reset with no Oops/backtrace. */
#define WBDBG(fmt, ...) pr_emerg("WBDBG " fmt "\n", ##__VA_ARGS__)
#endif
