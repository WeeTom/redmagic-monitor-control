@import Foundation;
#include <unistd.h>
#include "DDCNative.h"
int main(void){@autoreleasepool{
    GMDDCSession *s=gm_ddc_open();if(!s)return 2;NSMutableArray *rows=[NSMutableArray new];
    int waits[]={10,50,150};
    for(int c=2;c<=4;c++)for(int w=0;w<3;w++)for(int r=0;r<5;r++){
        CFAbsoluteTime start=CFAbsoluteTimeGetCurrent();GMDDCReply x=gm_ddc_read_tuned(s,0x10,c,50,waits[w],11);
        [rows addObject:@{@"count":@(c),@"wait":@(waits[w]),@"round":@(r),@"status":@(x.status),@"value":@(x.value),@"ms":@((CFAbsoluteTimeGetCurrent()-start)*1000)}];usleep(80000);
    }
    NSData *data=[NSJSONSerialization dataWithJSONObject:rows options:NSJSONWritingPrettyPrinted error:nil];fwrite(data.bytes,1,data.length,stdout);puts("");gm_ddc_close(s);return 0;
}}
