#ifndef COSTBAR_USAGE_H
#define COSTBAR_USAGE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* All timestamps are fractional Unix seconds. Buffers are caller-owned and
   borrowed only for the duration of a call; no allocation crosses the ABI. */
typedef struct { double updated_at; uint8_t available; } costbar_usage_provider_t;
typedef struct {
    size_t provider_index;
    double used_percent;
    double resets_at;
    uint8_t has_reset;
} costbar_usage_quota_t;
typedef struct {
    double generated_at;
    const costbar_usage_provider_t *providers;
    size_t provider_count;
    const costbar_usage_quota_t *quotas;
    size_t quota_count;
} costbar_usage_snapshot_t;
/* State: 0 active, 1 unavailable, 2 stale, 3 expired, 4 invalid. */
typedef struct { int64_t alert_window; uint32_t state; uint8_t should_alert; } costbar_usage_result_t;
typedef struct {
    /* quota_count means there is no eligible highest quota. */
    size_t highest_index;
    double next_transition;
    uint8_t stale;
    uint8_t has_next_transition;
} costbar_usage_summary_t;

uint8_t costbar_usage_is_stale(double updated_at, double now);
uint8_t costbar_usage_provider_is_fresh(double updated_at, uint8_t available, double now);
uint8_t costbar_usage_is_active(double reset, uint8_t has_reset, double now);
/* Returns 0 for invalid pointers/counts, otherwise writes quota_count results. */
uint8_t costbar_usage_evaluate(const costbar_usage_snapshot_t *snapshot, double now,
    uint32_t threshold, costbar_usage_result_t *results, size_t result_count,
    costbar_usage_summary_t *summary);
/* Returns bytes written, or 0 for invalid arguments/insufficient capacity. */
size_t costbar_usage_alert_key(const uint8_t *provider, size_t provider_len,
    const uint8_t *quota, size_t quota_len, int64_t window, uint32_t threshold,
    uint8_t *output, size_t capacity);
#ifdef __cplusplus
}
#endif
#endif
