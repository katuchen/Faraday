#ifndef CFARADAYSUPPORT_H
#define CFARADAYSUPPORT_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

pid_t faraday_audit_token_pid(const uint8_t *bytes, size_t length);

int faraday_audit_token_pidversion(const uint8_t *bytes, size_t length);

int faraday_proc_path(pid_t pid, char *buffer, uint32_t buffer_size);

pid_t faraday_proc_parent(pid_t pid);

int faraday_proc_args(pid_t pid, char *buffer, size_t *size);

size_t faraday_arg_max(void);

int faraday_boot_session_uuid(char *buffer, size_t buffer_size);

int faraday_list_pids(pid_t *pids, int capacity);

#ifdef __cplusplus
}
#endif

#endif
