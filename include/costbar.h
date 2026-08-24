#ifndef COSTBAR_H
#define COSTBAR_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define COSTBAR_ABI_VERSION 1u

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

uint32_t costbar_abi_version(void);
const char *costbar_version_string(void);

costbar_core_t *costbar_core_create(void);
void costbar_core_destroy(costbar_core_t *core);

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

void costbar_bytes_free(costbar_bytes_t bytes);

#ifdef __cplusplus
}
#endif

#endif
