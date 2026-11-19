@import Foundation;
#include <unistd.h>
#include "DDCNative.h"
int main(void){@autoreleasepool{
    GMDDCSession *s=gm_ddc_open();if(!s)return 2;NSMutableArray *rows=[NSMutableArray new];
    for(int i=0;i<20;i++){
        CFAbsoluteTime start=CFAbsoluteTimeGetCurrent();GMDDCReply r=gm_ddc_read_tuned(s,0x10,2,50,50,11);int polls=0;
        while(r.status!=0 && polls<3){r=gm_ddc_poll(s,0x10,0,60);polls++;}
        [rows addObject:@{@"round":@(i),@"status":@(r.status),@"value":@(r.value),@"polls":@(polls),@"elapsed_ms":@((CFAbsoluteTimeGetCurrent()-start)*1000)}];usleep(80000);
    }
    NSData *data=[NSJSONSerialization dataWithJSONObject:rows options:NSJSONWritingPrettyPrinted error:nil];fwrite(data.bytes,1,data.length,stdout);puts("");gm_ddc_close(s);return 0;
}}
