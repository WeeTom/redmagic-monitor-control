// Exercise the production write path with a stubbed I2C sender and a temporary lock.
#define IOAVServiceWriteI2C testWriteI2C
#include "../native/DDCNative.m"
#undef IOAVServiceWriteI2C
#include <assert.h>

static IOReturn replies[2];
static int count;
IOReturn testWriteI2C(IOAVServiceRef service, uint32_t chip, uint32_t offset,
                      void *buffer, uint32_t size) {
    (void)service; (void)chip; (void)offset; (void)buffer; (void)size;
    assert(count < 2);
    return replies[count++];
}

int main(void) {
    char path[] = "/tmp/redmagic-write-XXXXXX";
    GMDDCSession session = { .lock = mkstemp(path) };
    assert(session.lock >= 0);
    int competing = open(path, O_RDWR);
    unlink(path);
    assert(competing >= 0 && flock(competing, LOCK_EX | LOCK_NB) == 0);
    assert(gm_ddc_write(&session, 0x60, 8) == -2 && count == 0);
    close(competing);

    replies[1] = kIOReturnOffline;
    assert(gm_ddc_write(&session, 0x60, 8) == 0 && count == 2);
    count = 0;
    assert(gm_ddc_write(&session, 0x10, 50) == kIOReturnOffline && count == 2);
    count = 0;
    replies[0] = kIOReturnOffline;
    assert(gm_ddc_write(&session, 0x60, 8) == kIOReturnOffline && count == 1);
    close(session.lock);
    puts("PASS: input link drops after first send, other write failures, and busy lock");
}
