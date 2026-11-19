#ifndef GM_PROTOCOL_H
#define GM_PROTOCOL_H
#include <stdint.h>
#include <stddef.h>

/* Independent implementation of the GM001J protocol. No flash, arbitrary
 * command, power-mode or reset API is exposed. Milliseconds must
 * be monotonic; use a 64-bit clock on embedded hosts too. */
enum { GM_STATUS=0, GM_TYPEC=1, GM_DP=2, GM_HDMI1=3, GM_HDMI2=4, GM_TOGGLE=100 };
enum { GM_INPUT=0, GM_MODE=1, GM_HDR=2, GM_LIGHT_POWER=3, GM_LIGHT_COLOR=4,
       GM_LIGHT_LEVEL=5, GM_LIGHT_EFFECT=6, GM_FRONT_COLOR=7, GM_REAR_COLOR=8,
       GM_VOLUME_LAB=9 };
enum { GM_PENDING=0, GM_READ=1, GM_ALREADY=2, GM_SWITCHED=3,
       GM_TIMEOUT=-1, GM_MISMATCH=-2, GM_BAD_ACTION=-3 };
typedef struct {
    int action, reapply, phase, result, before, after, wanted;
    int feature, query_head, reply_head, group, set_head, before_limit;
    int set_writes, query_writes, stage_queries, samples, reconnects;
    uint64_t due, expires;
} GMState;
typedef struct { uint8_t bytes[3]; } GMFrame;
typedef struct { uint8_t bytes[3]; size_t used; } GMDecoder;

int gm_init(GMState *s, int action, int reapply, uint64_t now);
/* desired=-1 is query only. Stock firmware has no volume extension; it is
 * queried once, and writes require a successful fresh capability reply first.
 * Even a supporting firmware may only be set within the user's 0..10 limit. */
int gm_init_feature(GMState *s, int feature, int desired, int reapply, uint64_t now);
int gm_value_valid(int feature, int value, int for_write);
/* Call only when the transport is ready to immediately send WITHOUT_RESPONSE.
 * Returns one 3-byte command, or zero. Never combine commands into a BLE write. */
int gm_poll(GMState *s, uint64_t now, uint8_t command[3]);
void gm_input_reply(GMState *s, uint8_t value, uint64_t now);
void gm_frame_reply(GMState *s, const uint8_t frame[3], uint64_t now);
/* At most one reconnect; re-identify and re-subscribe before polling again.
 * A setter already sent is never replayed after a disconnect. */
int gm_reconnect(GMState *s, uint64_t now);
int gm_finished(const GMState *s);
const char *gm_result_name(const GMState *s);
void gm_decoder_reset(GMDecoder *d);
/* Strict known-frame parser; buffers at most two partial bytes, no byte search
 * to resynchronise arbitrary data. -1 drops the entire invalid notification.
 * Reset at each outgoing query and on connection changes. */
int gm_decode(GMDecoder *d, const uint8_t *data, size_t length,
              GMFrame *frames, size_t capacity);
#endif
