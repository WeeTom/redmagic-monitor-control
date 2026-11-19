@import Foundation;
#include <unistd.h>
#include "DDCNative.h"
int main(int argc,char **argv){@autoreleasepool{
    GMDDCSession *s=gm_ddc_open();if(!s)return 2;
    BOOL zero=argc==2 && strcmp(argv[1],"--volume-zero")==0;
    if(zero){
        int result=gm_ddc_write(s,0x62,0);
        fprintf(stderr,"Vendor-format volume 0 write returned %d. No increase sent.\n",result);
        usleep(300000);
    }
    NSMutableArray *rows=[NSMutableArray new];
    const uint8_t features[]={0x10,0x62,0x12};
    for(int mode=0;mode<2;mode++) for(int round=0;round<5;round++) for(int f=0;f<3;f++){
        CFAbsoluteTime start=CFAbsoluteTimeGetCurrent();GMDDCReply r=gm_ddc_read(s,features[f],mode,100);
        NSMutableString *raw=[NSMutableString new];for(int i=0;i<12;i++)[raw appendFormat:@"%02x",r.raw[i]];
        [rows addObject:@{@"vendor":@(mode),@"round":@(round),@"feature":@(features[f]),@"status":@(r.status),@"value":@(r.value),@"max":@(r.maximum),@"raw":raw,@"elapsed_ms":@((CFAbsoluteTimeGetCurrent()-start)*1000)}];
        usleep(50000);
    }
    NSData *data=[NSJSONSerialization dataWithJSONObject:rows options:NSJSONWritingPrettyPrinted error:nil];fwrite(data.bytes,1,data.length,stdout);puts("");gm_ddc_close(s);return 0;
}}
