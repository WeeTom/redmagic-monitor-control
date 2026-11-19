@import Foundation;
#include <unistd.h>
#include "../native/TargetDisplay.h"
#include "i2c.h"
// Every transfer is a Get VCP 0x10 request or read; no setting writes.
int main(int argc,char **argv) { @autoreleasepool {
    int mode=argc>1 ? atoi(argv[1]):0;
    DisplayInfos displays[16];if(mode==2)getOnlineDisplayInfos(displays);
    AVServiceInfos infos[16]={};int n=getAVServiceInfos(infos,16);
    AVServiceInfos *info=GMFindTarget(infos,n,GMConfiguredSerial());if(!info)return 2;
    DDCTransport t=getAVServiceDDCTransport(info);if(!t.service)return 3;
    if(mode==1)releaseAVServiceInfos(infos,n);
    NSMutableArray *results=[NSMutableArray new];
    for(int test=0;test<5;test++) {
        DDCPacket p=createDDCPacket(0x10);prepareDDCRead(&p);IOReturn write=0;
        if(mode==3)write=performDDCWriteAtChipAddress(t.service,t.chipAddress,&p);
        else for(int i=0;i<2;i++){usleep(50000);write=IOAVServiceWriteI2C(t.service,t.chipAddress,p.inputAddr,p.data,4);}
        usleep(150000);UInt8 reply[12]={};IOReturn read=IOAVServiceReadI2C(t.service,t.chipAddress,0x51,reply,12);
        NSMutableString *hex=[NSMutableString new];for(int i=0;i<12;i++)[hex appendFormat:@"%02x",reply[i]];
        [results addObject:@{@"mode":@(mode),@"iteration":@(test),@"raw":hex,@"valid":@(!write&&!read&&validDDCReply(reply,0x10)&&reply[3]==0)}];
        usleep(150000);
    }
    NSData *data=[NSJSONSerialization dataWithJSONObject:results options:NSJSONWritingPrettyPrinted error:nil];fwrite(data.bytes,1,data.length,stdout);puts("");
    CFRelease(t.service);releaseAVServiceInfos(infos,n);return 0;
}}
