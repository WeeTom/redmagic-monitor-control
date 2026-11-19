#ifndef GM_DDC_NATIVE_H
#define GM_DDC_NATIVE_H
#include <stdint.h>
typedef struct GMDDCSession GMDDCSession;
typedef struct {
    int status; /* 0=validated, 1=invalid, 2=busy, 3=I/O or unavailable */
    int io_error;
    int length;
    int vendor;
    uint16_t value, maximum;
    uint8_t raw[16];
} GMDDCReply;
GMDDCSession *gm_ddc_open(void);
GMDDCSession *gm_ddc_open_for_serial(const char *serial);
void gm_ddc_close(GMDDCSession *s);
GMDDCReply gm_ddc_read(GMDDCSession *s, uint8_t feature, int vendor, int wait_ms);
GMDDCReply gm_ddc_poll(GMDDCSession *s, uint8_t feature, int vendor, int wait_ms);
GMDDCReply gm_ddc_read_tuned(GMDDCSession *s,uint8_t feature,int requests,int gap_ms,int wait_ms,int read_length);
/* Absolute values only. Monitor-bound allowlist; volume uses the confirmed
 * factory C8 format for values from 0 to 100. */
int gm_ddc_write(GMDDCSession *s, uint8_t feature, uint16_t value);
int gm_ddc_validate(const uint8_t *raw,int length,uint8_t feature,int vendor,GMDDCReply *out);
int gm_ddc_can_write(uint8_t feature,uint16_t value);
#endif
