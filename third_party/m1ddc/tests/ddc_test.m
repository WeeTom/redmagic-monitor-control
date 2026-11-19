@import Foundation;
@import IOKit;
#include <assert.h>
#include "i2c.h"

static uint32_t lastLength;
IOReturn IOAVServiceWriteI2C(IOAVServiceRef s, uint32_t a, uint32_t o, void *b, uint32_t n) {
    (void)s; (void)a; (void)o; (void)b; lastLength=n; return 0;
}
IOReturn IOAVServiceReadI2C(IOAVServiceRef s, uint32_t a, uint32_t o, void *b, uint32_t n) {
    (void)s; (void)a; (void)o; memset(b,0,n); return 0;
}
static void checksum(UInt8 *r) {
    r[10]=0x50;
    for(int i=0;i<10;i++) r[10]^=r[i];
}
int main(void) {
 @autoreleasepool {
    UInt8 reply[12]={0x6e,0x88,0x02,0,0x60,0,0x00,0xff,0x12,0x34,0,0};
    checksum(reply);
    assert(validDDCReply(reply,0x60));
    DDCValue value=convertI2CtoDDC((char*)reply);
    assert(value.maxValue==255 && value.curValue==4660);
    assert(!validDDCReply(reply,0x10));
    reply[9]^=1; assert(!validDDCReply(reply,0x60)); reply[9]^=1;
    reply[1]=0x87; checksum(reply); assert(!validDDCReply(reply,0x60));
    UInt8 invalid[12]={0x6e,0xa7,0x8d,0x33,0x39,0x30,0x36,0x30,0x31,0x33,0x32,0};
    assert(!validDDCReply(invalid,0x60));
    DDCPacket packet=createDDCPacket(INPUT);
    prepareDDCWrite(&packet,216); // This particular frame has a zero checksum.
    assert(packet.data[5]==0);
    assert(performDDCWrite(NULL,&packet)==0 && lastLength==6);
    prepareDDCRead(&packet);
    assert(performDDCWrite(NULL,&packet)==0 && lastLength==4);
    puts("PASS: decoding, checksum, VCP mismatch, malformed frame, zero-checksum write length");
 }
}
