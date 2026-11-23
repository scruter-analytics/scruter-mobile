// Scruter Analytics: the crash handlers of the iOS SDK (docs/MOBILE.md §3.10).
//
// POSIX signal handlers and a Mach exception handler write a minimal, async-signal-safe report (thread states, raw
// return addresses, the binary images' UUIDs and load addresses, the SDK's context: session, screen, breadcrumbs) to a
// file opened in advance. The SDK reads it at the next launch and sends it with its first batch. Previously installed
// handlers are chained, so other crash reporters keep working.
#ifndef SCRUTER_CRASH_H
#define SCRUTER_CRASH_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Installs the handlers, writing reports to `report_path` (opened now, never truncated before a crash).
/// `use_mach` = also install the Mach exception handler (skipped when a debugger or another handler holds the task's
/// exception ports). Returns 0 on success.
int scruter_crash_install(const char *report_path, int use_mach);

/// Restores the previous handlers.
void scruter_crash_uninstall(void);

/// The context written with a report: one line of JSON (`{"s":…,"scr":…,"fg":…,"bc":[…],"lt":…}`), ≤ 4 KB.
void scruter_crash_set_context(const char *json, size_t length);

/// Writes no report for the next `milliseconds`: a JavaScript or Dart fatal error, reported by its own layer, ends in a
/// native abort that would count the same crash twice. The handlers still chain.
void scruter_crash_mute(uint32_t milliseconds);

/// Writes the report of an uncaught Objective-C exception (`type` its name, `reason` its reason), with the
/// exception's return addresses; the process aborts afterwards and the signal handler only chains.
int scruter_crash_write_exception(const char *type, const char *reason, const uintptr_t *addresses, size_t count);

/// Writes a report of the calling thread without crashing (tests only).
int scruter_crash_write_test_report(const char *type);

/// 1 when the handlers are installed, 2 when the Mach handler is too.
int scruter_crash_installed(void);

#ifdef __cplusplus
}
#endif

#endif
