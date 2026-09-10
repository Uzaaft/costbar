#ifndef COSTBAR_H
#define COSTBAR_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define COSTBAR_ABI_VERSION 13u

typedef struct costbar_core costbar_core_t;

typedef enum costbar_status {
    COSTBAR_STATUS_OK = 0,
    COSTBAR_STATUS_INVALID_ARGUMENT = 1,
    COSTBAR_STATUS_OUT_OF_MEMORY = 2,
    COSTBAR_STATUS_INTERNAL_ERROR = 3,
    COSTBAR_STATUS_PARSE_ERROR = 4,
    COSTBAR_STATUS_UNSUPPORTED = 5,
    COSTBAR_STATUS_MAX_VALUE = INT32_MAX
} costbar_status_t;

typedef struct costbar_bytes {
    const uint8_t *ptr;
    size_t len;
} costbar_bytes_t;

typedef struct costbar_refresh_options {
    int64_t period_start_unix;
    int64_t period_end_exclusive_unix;
    uint8_t track_codex;
    uint8_t track_claude;
    uint8_t track_opencode;
    uint8_t use_github_cli;
    uint8_t has_source_filter;
    uint8_t write_cache;
    costbar_bytes_t source_ids;
    costbar_bytes_t cache_key;
} costbar_refresh_options_t;

typedef struct costbar_refresh_result {
    uint32_t configured_count;
    uint32_t refreshed_count;
    costbar_bytes_t errors;
} costbar_refresh_result_t;

typedef struct costbar_optional_i64 {
    int64_t value;
    uint8_t present;
} costbar_optional_i64_t;

typedef struct costbar_snapshot_header {
    int64_t period_start_unix;
    int64_t period_end_exclusive_unix;
    int64_t generated_at_unix;
    size_t total_count;
    size_t provider_count;
} costbar_snapshot_header_t;

typedef struct costbar_currency_total_view {
    costbar_bytes_t currency;
    int64_t current_cost_micros;
    costbar_optional_i64_t projected_cost_micros;
    costbar_optional_i64_t credit_remaining_micros;
    uint8_t projection_complete;
    uint8_t credit_complete;
} costbar_currency_total_view_t;

typedef struct costbar_provider_view {
    costbar_bytes_t id;
    costbar_bytes_t display_name;
    costbar_bytes_t kind;
    costbar_bytes_t status;
    costbar_bytes_t error_message;
    uint8_t has_error_message;
    costbar_bytes_t currency;
    int64_t current_cost_micros;
    costbar_optional_i64_t projected_cost_micros;
    costbar_optional_i64_t credit_remaining_micros;
    uint8_t contributes_to_totals;
    int64_t updated_at_unix;
    size_t resource_count;
    size_t line_item_count;
    size_t allowance_count;
    uint8_t has_token_usage;
    size_t token_usage_window_count;
    size_t token_usage_series_count;
    size_t spend_series_count;
    size_t financial_count;
} costbar_provider_view_t;

typedef struct costbar_resource_view {
    costbar_bytes_t id;
    costbar_bytes_t name;
    costbar_bytes_t kind;
    costbar_bytes_t status;
    uint64_t quantity;
} costbar_resource_view_t;

typedef struct costbar_cost_line_item_view {
    costbar_bytes_t id;
    costbar_bytes_t description;
    costbar_bytes_t service;
    int64_t amount_micros;
    costbar_bytes_t currency;
    uint8_t has_currency;
    costbar_bytes_t detail;
    uint8_t has_detail;
} costbar_cost_line_item_view_t;

typedef struct costbar_allowance_view {
    costbar_bytes_t id;
    costbar_bytes_t label;
    double used_percent;
    costbar_optional_i64_t resets_at_unix;
    costbar_optional_i64_t duration_minutes;
    costbar_bytes_t detail;
    uint8_t has_detail;
} costbar_allowance_view_t;

/* How an allowance is tracking against its own clock. empties_at_unix is an
 * absolute instant rather than a countdown, so one computation renders a live
 * "empty in 40m". */
typedef struct costbar_allowance_pace_view {
    double deviation_points;
    costbar_optional_i64_t empties_at_unix;
    int64_t resets_at_unix;
} costbar_allowance_pace_view_t;

typedef struct costbar_token_usage_view {
    int64_t period_start_unix;
    int64_t period_end_exclusive_unix;
    uint64_t input_tokens;
    uint64_t output_tokens;
    uint64_t cache_read_tokens;
    uint64_t cache_creation_tokens;
    uint64_t reasoning_tokens;
    costbar_bytes_t source;
    int64_t updated_at_unix;
} costbar_token_usage_view_t;

typedef struct costbar_token_usage_window_view {
    costbar_bytes_t id;
    costbar_bytes_t label;
    int64_t period_start_unix;
    int64_t period_end_exclusive_unix;
    uint64_t input_tokens;
    uint64_t output_tokens;
    uint64_t cache_read_tokens;
    uint64_t cache_creation_tokens;
    uint64_t reasoning_tokens;
} costbar_token_usage_window_view_t;

typedef struct costbar_token_usage_series_view {
    costbar_bytes_t id;
    costbar_bytes_t label;
    int64_t period_start_unix;
    int64_t period_end_exclusive_unix;
    size_t bucket_count;
} costbar_token_usage_series_view_t;

typedef struct costbar_token_usage_bucket_view {
    int64_t period_start_unix;
    int64_t period_end_exclusive_unix;
    uint64_t input_tokens;
    uint64_t output_tokens;
    uint64_t cache_read_tokens;
    uint64_t cache_creation_tokens;
    uint64_t reasoning_tokens;
} costbar_token_usage_bucket_view_t;

typedef struct costbar_spend_series_view {
    costbar_bytes_t id;
    costbar_bytes_t label;
    costbar_bytes_t currency;
    int64_t period_start_unix;
    int64_t period_end_exclusive_unix;
    size_t bucket_count;
} costbar_spend_series_view_t;

typedef struct costbar_spend_bucket_view {
    int64_t period_start_unix;
    int64_t period_end_exclusive_unix;
    int64_t amount_micros;
    uint64_t usage_quantity;
} costbar_spend_bucket_view_t;

typedef struct costbar_financial_view {
    costbar_bytes_t currency;
    int64_t current_cost_micros;
    costbar_optional_i64_t projected_cost_micros;
    costbar_optional_i64_t credit_remaining_micros;
} costbar_financial_view_t;

typedef struct costbar_snapshot costbar_snapshot_t;

uint32_t costbar_abi_version(void);
const char *costbar_version_string(void);

costbar_status_t costbar_claude_status_bridge_is_installed(uint8_t *out_installed);
costbar_status_t costbar_claude_status_bridge_install(void);
costbar_status_t costbar_claude_status_bridge_restore(void);

typedef struct costbar_session_monitor costbar_session_monitor_t;

costbar_session_monitor_t *costbar_session_monitor_create(void);
void costbar_session_monitor_destroy(costbar_session_monitor_t *monitor);
costbar_status_t costbar_session_monitor_set_roots(
    costbar_session_monitor_t *monitor,
    costbar_bytes_t roots
);
costbar_status_t costbar_session_monitor_poll(
    costbar_session_monitor_t *monitor,
    int64_t now_unix,
    costbar_bytes_t *out_json
);
costbar_status_t costbar_session_monitor_transitions(
    costbar_session_monitor_t *monitor,
    costbar_bytes_t *out_json
);

costbar_core_t *costbar_core_create(void);
void costbar_core_destroy(costbar_core_t *core);

/* Returns newline-delimited organizations visible to the active gh session. */
costbar_status_t costbar_github_cli_organizations(
    costbar_bytes_t *out_organizations
);

/* Copies one credential/configuration value into Zig-owned memory. */
costbar_status_t costbar_core_set_setting(
    costbar_core_t *core,
    costbar_bytes_t key,
    costbar_bytes_t value
);

/* Decodes one field from the legacy packed credential JSON in Zig. */
costbar_status_t costbar_decode_credential_json_field(
    costbar_bytes_t json,
    costbar_bytes_t key,
    costbar_bytes_t *out_value
);

/* Concurrently refreshes all configured remote and selected local providers. */
costbar_status_t costbar_core_refresh(
    costbar_core_t *core,
    costbar_refresh_options_t options,
    costbar_refresh_result_t *out_result
);

/*
 * Ingests one provider API response. Provider/document identifiers are stable
 * UTF-8 names such as ("digitalocean", "balance"),
 * ("digitalocean", "droplets"), or ("cloudflare", "subscriptions").
 * All input views are borrowed for the duration of the call.
 */
costbar_status_t costbar_core_ingest_provider_json(
    costbar_core_t *core,
    costbar_bytes_t provider_id,
    costbar_bytes_t document_id,
    costbar_bytes_t json,
    int64_t received_at_unix
);

/*
 * Returns a UTF-8 JSON dashboard snapshot. The caller owns `out_json` on
 * success and must release it with costbar_bytes_free.
 */
costbar_status_t costbar_core_snapshot_json(
    costbar_core_t *core,
    int64_t period_start_unix,
    int64_t period_end_exclusive_unix,
    costbar_bytes_t *out_json
);

/* Typed snapshot API. All returned strings are borrowed until destroy. */
costbar_status_t costbar_core_snapshot_create(
    costbar_core_t *core,
    int64_t period_start_unix,
    int64_t period_end_exclusive_unix,
    costbar_snapshot_t **out_snapshot
);
costbar_status_t costbar_core_cached_snapshot_create(
    costbar_core_t *core,
    int64_t period_start_unix,
    int64_t period_end_exclusive_unix,
    costbar_snapshot_t **out_snapshot
);
costbar_status_t costbar_core_cached_account_snapshot_create(
    costbar_core_t *core,
    costbar_bytes_t cache_key,
    int64_t period_start_unix,
    int64_t period_end_exclusive_unix,
    costbar_snapshot_t **out_snapshot
);
void costbar_snapshot_destroy(costbar_snapshot_t *snapshot);
costbar_status_t costbar_snapshot_header(
    const costbar_snapshot_t *snapshot,
    costbar_snapshot_header_t *out_header
);
costbar_status_t costbar_snapshot_total(
    const costbar_snapshot_t *snapshot,
    size_t index,
    costbar_currency_total_view_t *out_total
);
costbar_status_t costbar_snapshot_provider(
    const costbar_snapshot_t *snapshot,
    size_t index,
    costbar_provider_view_t *out_provider
);
costbar_status_t costbar_snapshot_resource(
    const costbar_snapshot_t *snapshot,
    size_t provider_index,
    size_t index,
    costbar_resource_view_t *out_resource
);
costbar_status_t costbar_snapshot_line_item(
    const costbar_snapshot_t *snapshot,
    size_t provider_index,
    size_t index,
    costbar_cost_line_item_view_t *out_item
);
costbar_status_t costbar_snapshot_allowance(
    const costbar_snapshot_t *snapshot,
    size_t provider_index,
    size_t index,
    costbar_allowance_view_t *out_allowance
);
/* Computes how an allowance is tracking against its own clock at now_unix.
 * Takes the window's values rather than a snapshot index, so a consumer can
 * call it from a decoded copy at any time. Returns
 * COSTBAR_STATUS_UNSUPPORTED when the window carries no honest verdict: no
 * reset, no length, a reset the clock disagrees with, or too little of the
 * window elapsed to imply a rate. */
costbar_status_t costbar_allowance_pace(
    double used_percent,
    costbar_optional_i64_t resets_at_unix,
    costbar_optional_i64_t duration_minutes,
    int64_t now_unix,
    costbar_allowance_pace_view_t *out_pace
);
costbar_status_t costbar_snapshot_token_usage(
    const costbar_snapshot_t *snapshot,
    size_t provider_index,
    costbar_token_usage_view_t *out_usage
);
costbar_status_t costbar_snapshot_token_usage_window(
    const costbar_snapshot_t *snapshot,
    size_t provider_index,
    size_t index,
    costbar_token_usage_window_view_t *out_window
);
costbar_status_t costbar_snapshot_token_usage_series(
    const costbar_snapshot_t *snapshot,
    size_t provider_index,
    size_t index,
    costbar_token_usage_series_view_t *out_series
);
costbar_status_t costbar_snapshot_token_usage_bucket(
    const costbar_snapshot_t *snapshot,
    size_t provider_index,
    size_t series_index,
    size_t index,
    costbar_token_usage_bucket_view_t *out_bucket
);
costbar_status_t costbar_snapshot_spend_series(
    const costbar_snapshot_t *snapshot,
    size_t provider_index,
    size_t index,
    costbar_spend_series_view_t *out_series
);
costbar_status_t costbar_snapshot_spend_bucket(
    const costbar_snapshot_t *snapshot,
    size_t provider_index,
    size_t series_index,
    size_t index,
    costbar_spend_bucket_view_t *out_bucket
);
costbar_status_t costbar_snapshot_financial(
    const costbar_snapshot_t *snapshot,
    size_t provider_index,
    size_t index,
    costbar_financial_view_t *out_financial
);

void costbar_bytes_free(costbar_bytes_t bytes);

#ifdef __cplusplus
}
#endif

#endif
