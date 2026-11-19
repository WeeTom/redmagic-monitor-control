@import Foundation;
#include <unistd.h>
#include "../native/TargetDisplay.h"
#include "i2c.h"
// Read-only diagnostic: the only DDC command sent is Get VCP 0x10.
int main(void) { @autoreleasepool {
    AVServiceInfos infos[16]={};int n=getAVServiceInfos(infos,16);
    AVServiceInfos *info=GMFindTarget(infos,n,GMConfiguredSerial());
    if (!info) return 2;
    DDCTransport t=getAVServiceDDCTransport(info);
    if (!t.service) return 3;
    NSMutableArray *results=[NSMutableArray new];
    const unsigned waits[]={50000,150000,350000,700000};
    const unsigned offsets[]={0,0x51};
    for (int count=1;count<=2;count++) for (int o=0;o<2;o++) for (int w=0;w<4;w++) {
        DDCPacket p=createDDCPacket(0x10);prepareDDCRead(&p);IOReturn write=0;
        for (int i=0;i<count;i++) { usleep(50000);write=IOAVServiceWriteI2C(t.service,t.chipAddress,p.inputAddr,p.data,4); }
        usleep(waits[w]);UInt8 reply[12]={};
        IOReturn read=IOAVServiceReadI2C(t.service,t.chipAddress,offsets[o],reply,sizeof(reply));
        NSMutableString *hex=[NSMutableString new];for (int i=0;i<12;i++) [hex appendFormat:@"%02x",reply[i]];
        BOOL valid=!write&&!read&&validDDCReply(reply,0x10)&&reply[3]==0;
        [results addObject:@{@"get_request_count":@(count),@"read_offset":@(offsets[o]),@"wait_microseconds":@(waits[w]),@"write_return":@(write),@"read_return":@(read),@"raw":hex,@"valid":@(valid)}];
        usleep(150000);
    }
    NSData *data=[NSJSONSerialization dataWithJSONObject:results options:NSJSONWritingPrettyPrinted error:nil];
    fwrite(data.bytes,1,data.length,stdout);puts("");
    CFRelease(t.service);releaseAVServiceInfos(infos,n);return 0;
}}
