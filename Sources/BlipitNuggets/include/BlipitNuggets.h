#ifndef BLIPIT_NUGGETS_H
#define BLIPIT_NUGGETS_H

#include <stdint.h>

int bn_install(const char *crash_path, int use_mach);
int bn_installed(void);
void bn_mark_main_thread(void);
int bn_main_backtrace(uintptr_t *out, int max);
int bn_write_exception(const char *name, const char *reason, const uintptr_t *frames, int count);
int bn_debugger_attached(void);
int64_t bn_boot_time(void);
int64_t bn_process_start_ms(void);
int bn_image_count(void);
int bn_image_at(int index, uintptr_t *base, uintptr_t *size, char *uuid_hex, const char **path);
int bn_backtrace(uintptr_t *out, int max, int skip);
void bn_crash(int how);

#endif
