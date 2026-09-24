#ifndef HARD_PAUSE_CORE_H
#define HARD_PAUSE_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint8_t *ptr;
    size_t len;
} HpCoreBuffer;

/* Returns 0 with a JSON response, -1 for invalid pointers, or -2 on internal failure.
 * The caller owns out on return 0 and must release it with hp_core_free.
 * Request: {"version":1,"op":"...","args":{...}}.
 * Response: {"ok":true,"result":...} or {"ok":false,"error":{"code":"..."}}.
 */
int32_t hp_core_call(const uint8_t *input, size_t input_len, HpCoreBuffer *out);
void hp_core_free(HpCoreBuffer buffer);

typedef struct HpDomainIndex HpDomainIndex;

#define HP_DOMAIN_FORMAT_BLOCK_LIST_PROJECT 1u
#define HP_DOMAIN_FORMAT_HARD_PAUSE_SUPPLEMENT 2u

/* Parse raw UTF-8 list bytes once. The list size/count and metadata are checked
 * by the same portable parser used by the JSON API. For the block list, pass
 * minimum_count and category=NULL/category_len=0. For a supplement, pass a
 * UTF-8 category; minimum_count is ignored. On failure *out_index is NULL.
 * Returns 0 on success, -1 for invalid arguments, -2 for invalid list data,
 * or -3 for internal failure. The caller owns the handle.
 */
int32_t hp_domain_index_create(const uint8_t *data, size_t data_len,
                               uint32_t format, size_t minimum_count,
                               const uint8_t *category, size_t category_len,
                               HpDomainIndex **out_index);

/* Read-only lookup on a canonical ASCII host. The handle may be shared among
 * concurrent lookups. Returns 0 and sets *out_contains to 0 or 1; -1 means
 * invalid arguments, -3 means internal failure. A NULL host with length 0 is
 * an empty host and returns 0 in *out_contains.
 */
int32_t hp_domain_index_contains(const HpDomainIndex *index,
                                 const uint8_t *host, size_t host_len,
                                 uint8_t *out_contains);

/* Export the parsed domains and metadata as JSON without parsing again.
 * Returns 0 on success; release *out with hp_core_free.
 */
int32_t hp_domain_index_export(const HpDomainIndex *index, HpCoreBuffer *out);

/* NULL is allowed. Call once after all lookups finish. */
void hp_domain_index_free(HpDomainIndex *index);

#ifdef __cplusplus
}
#endif

#endif
