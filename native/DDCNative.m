@import Foundation;
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include "DDCNative.h"
#include "TargetDisplay.h"
#include "i2c.h"

struct GMDDCSession { IOAVServiceRef service; io_service_t proxy; uint32_t chip; int lock; };
static int readable(uint8_t f) {
    return f==0x10 || f==0x12 || f==0x60 || f==0x62;
}
int gm_ddc_can_write(uint8_t f,uint16_t v) {
    if(f==0x60)return v>=5 && v<=8; /* GM001J: HDMI1, HDMI2, Type-C, DP */
    return readable(f) && v<=100;
}
GMDDCSession *gm_ddc_open(void) { @autoreleasepool {
    return gm_ddc_open_for_serial(GMConfiguredSerial().UTF8String);
}}
GMDDCSession *gm_ddc_open_for_serial(const char *serial) { @autoreleasepool {
    if (!serial || !*serial) return NULL;
    AVServiceInfos infos[16]={};int n=getAVServiceInfos(infos,16);
    AVServiceInfos *selected=GMFindTarget(infos,n,[NSString stringWithUTF8String:serial]);
    if(!selected){releaseAVServiceInfos(infos,n);return NULL;}
    DDCTransport t=getAVServiceDDCTransport(selected);
    if(!t.service){releaseAVServiceInfos(infos,n);return NULL;}
    GMDDCSession *s=calloc(1,sizeof(*s));
    if(!s){CFRelease(t.service);releaseAVServiceInfos(infos,n);return NULL;}
    s->lock=-1;
    s->service=t.service;s->proxy=selected->proxy;s->chip=t.chipAddress;
    IOObjectRetain(s->proxy);releaseAVServiceInfos(infos,n);
    NSString *folder=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/com.local.redmagic-display"];
    [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    s->lock=open([[folder stringByAppendingPathComponent:@"ddc.lock"] fileSystemRepresentation],O_CREAT|O_RDWR,0600);
    if(s->lock<0){gm_ddc_close(s);return NULL;}
    return s;
}}
void gm_ddc_close(GMDDCSession *s) {
    if(!s)return;
    if(s->service)CFRelease(s->service);
    if(s->proxy)IOObjectRelease(s->proxy);
    if(s->lock>=0)close(s->lock);
    free(s);
}
int gm_ddc_validate(const uint8_t *r,int length,uint8_t feature,int vendor,GMDDCReply *out) {
    const int n=vendor ? 12:11;
    if(length<n || r[0]!=0x6e || r[1]!=(vendor ? 0x89:0x88) || r[2]!=(vendor ? 0xc7:2))return 0;
    int shift=vendor ? 1:0;
    if(vendor && r[3]!=0)return 0;
    if(r[3+shift]!=0 || r[4+shift]!=feature)return 0;
    uint8_t checksum=0x50;for(int i=0;i<n;i++)checksum^=r[i];
    if(checksum)return 0;
    out->maximum=(uint16_t)(r[6+shift]<<8|r[7+shift]);
    out->value=(uint16_t)(r[8+shift]<<8|r[9+shift]);
    out->length=n;out->status=0;out->vendor=vendor;return 1;
}
static IOReturn send(GMDDCSession *s,const uint8_t *bytes,uint32_t length) {
    return IOAVServiceWriteI2C(s->service,s->chip,0x51,(void *)bytes,length);
}
GMDDCReply gm_ddc_read(GMDDCSession *s,uint8_t f,int vendor,int wait_ms) {
    GMDDCReply out={.status=3,.vendor=vendor};
    if(!s || !readable(f))return out;
    if(flock(s->lock,LOCK_EX|LOCK_NB)){out.status=2;return out;}
    uint8_t data[5]={0};int len;
    if(vendor){data[0]=0x83;data[1]=0xc6;data[2]=0;data[3]=f;len=5;}
    else{data[0]=0x82;data[1]=1;data[2]=f;len=4;}
    uint8_t crc=0x6e^0x51;for(int i=0;i<len-1;i++)crc^=data[i];data[len-1]=crc;
    IOReturn err=0;
    for(int i=0;i<2;i++){usleep(20000);err=send(s,data,(uint32_t)len);if(err)break;}
    if(!err){
        int delay=wait_ms<20 ? 20:wait_ms>700 ? 700:wait_ms;
        usleep((useconds_t)(delay*1000));
        err=IOAVServiceReadI2C(s->service,s->chip,0x51,out.raw,12);
    }
    flock(s->lock,LOCK_UN);out.io_error=(int)err;out.length=12;
    if(err)return out;
    out.status=1;gm_ddc_validate(out.raw,12,f,vendor,&out);
    return out;
}
int gm_ddc_write(GMDDCSession *s,uint8_t f,uint16_t v) {
    if(!s || !gm_ddc_can_write(f,v))return -1;
    if(flock(s->lock,LOCK_EX|LOCK_NB))return -2;
    uint8_t data[7]={0};int len;
    if(f==0x62){data[0]=0x85;data[1]=0xc8;data[2]=0;data[3]=f;data[4]=0;data[5]=(uint8_t)v;len=7;}
    else{data[0]=0x84;data[1]=3;data[2]=f;data[3]=(uint8_t)(v>>8);data[4]=(uint8_t)v;len=6;}
    uint8_t crc=0x6e^0x51;for(int i=0;i<len-1;i++)crc^=data[i];data[len-1]=crc;
    usleep(50000);IOReturn result=send(s,data,(uint32_t)len);
    if(!result){usleep(50000);result=send(s,data,(uint32_t)len);}
    flock(s->lock,LOCK_UN);return (int)result;
}
GMDDCReply gm_ddc_poll(GMDDCSession *s,uint8_t f,int vendor,int wait_ms){
    GMDDCReply out={.status=3,.vendor=vendor};
    if(!s || !readable(f))return out;
    if(flock(s->lock,LOCK_EX|LOCK_NB)){out.status=2;return out;}
    int delay=wait_ms<20 ? 20:wait_ms>700 ? 700:wait_ms;
    usleep((useconds_t)(delay*1000));
    IOReturn err=IOAVServiceReadI2C(s->service,s->chip,0x51,out.raw,12);
    flock(s->lock,LOCK_UN);out.length=12;out.io_error=(int)err;
    if(!err){out.status=1;gm_ddc_validate(out.raw,12,f,vendor,&out);}
    return out;
}
GMDDCReply gm_ddc_read_tuned(GMDDCSession *s,uint8_t f,int requests,int gap_ms,int wait_ms,int read_length){
    GMDDCReply out={.status=3};if(!s || !readable(f))return out;
    if(flock(s->lock,LOCK_EX|LOCK_NB)){out.status=2;return out;}
    if(requests<1 || requests>4 || gap_ms<10 || gap_ms>150 || wait_ms<10 || wait_ms>700 || (read_length!=11 && read_length!=12)){flock(s->lock,LOCK_UN);return out;}
    uint8_t data[]={0x82,1,f,(uint8_t)(0x6e^0x51^0x82^1^f)};IOReturn err=0;
    for(int i=0;i<requests;i++){usleep((useconds_t)(gap_ms*1000));err=send(s,data,4);if(err)break;}
    if(!err){usleep((useconds_t)(wait_ms*1000));err=IOAVServiceReadI2C(s->service,s->chip,0x51,out.raw,(uint32_t)read_length);}
    flock(s->lock,LOCK_UN);out.length=read_length;out.io_error=(int)err;
    if(!err){out.status=1;gm_ddc_validate(out.raw,read_length,f,0,&out);}return out;
}
