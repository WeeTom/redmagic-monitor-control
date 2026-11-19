@import Foundation;
#include <unistd.h>
#include "DDCNative.h"
int main(void){@autoreleasepool{
    GMDDCSession *s=gm_ddc_open();if(!s)return 2;NSMutableArray *rows=[NSMutableArray new];
    for(int count=1;count<=2;count++)for(int len=11;len<=12;len++)for(int w=0;w<2;w++)for(int r=0;r<5;r++){
        CFAbsoluteTime start=CFAbsoluteTimeGetCurrent();GMDDCReply x=gm_ddc_read_tuned(s,0x10,count,50,w ? 150:50,len);
        NSMutableString *raw=[NSMutableString new];for(int i=0;i<len;i++)[raw appendFormat:@"%02x",x.raw[i]];
        [rows addObject:@{@"count":@(count),@"length":@(len),@"wait":@(w ? 150:50),@"round":@(r),@"status":@(x.status),@"value":@(x.value),@"raw":raw,@"ms":@((CFAbsoluteTimeGetCurrent()-start)*1000)}];usleep(70000);
    }
    NSData *data=[NSJSONSerialization dataWithJSONObject:rows options:NSJSONWritingPrettyPrinted error:nil];fwrite(data.bytes,1,data.length,stdout);puts("");gm_ddc_close(s);return 0;
}}
