#ifndef VHDX_APP_H
#define VHDX_APP_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* ABI version 9 (optional shared plaintext disk cache management). Call the blocking request function from a non-UI thread.
   Requests are serialized on a separate Rust worker. It owns all native handles.
   JSON and UTF-8 input length is bounded to 1 MiB. Passwords must never be logged.
   Each successful allocation must be released with vhdx_response_free, not free(). */
uint32_t vhdx_api_version(void);
uint64_t vhdx_context_create(void);
/* Host teardown: snapshot IDs, then retire off the UI thread before releasing grants. */
uint64_t vhdx_context_watermark(void);
uint8_t vhdx_retire_contexts_before(uint64_t before);
/* Include op=dispose when releasing a context.
   thumbnail_begin/cancel/finish are bounded metadata-only controls that bypass
   the worker and may be invoked on the UI thread, even during media_open.
   All other requests retain the non-UI-thread requirement above. */
char *vhdx_request(uint64_t context, const uint8_t *input, size_t length);
void vhdx_response_free(char *response);
/* Cooperative cancellation of this context only, between I/O chunks. */
void vhdx_cancel(uint64_t context);
/* Optional ABI 7 extension. Register as mpv_stream_cb_add_ro's open_fn for
   protocol "vhdx", user_data=NULL. Requires libmpv API 1.106+ or 2.x.
   Keep this library loaded through mpv_terminate_destroy, including delayed
   media_kit destruction. Stream cookies are released only by mpv close_fn. */
struct mpv_stream_cb_info;
int vhdx_mpv_open(void *user_data, char *uri, struct mpv_stream_cb_info *info);
#ifdef __cplusplus
}
#endif
#endif
