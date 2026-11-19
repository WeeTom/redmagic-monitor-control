@import Foundation;
#include <unistd.h>
#include "DDCNative.h"
int main(void){@autoreleasepool{
    GMDDCSession *s=gm_ddc_open();if(!s)return 2;
    int sent=gm_ddc_write(s,0x62,0);fprintf(stderr,"Only volume zero sent, result %d\n",sent);
    NSMutableArray *rows=[NSMutableArray new];
    for(int i=0;i<24;i++){
        int mode=i<8 ? 1:0;
        GMDDCReply r=i<4 ? gm_ddc_poll(s,0x62,1,200):gm_ddc_read(s,0x62,mode,200);
        NSMutableString *raw=[NSMutableString new];for(int j=0;j<12;j++)[raw appendFormat:@"%02x",r.raw[j]];
        [rows addObject:@{@"step":@(i),@"vendor":@(mode),@"status":@(r.status),@"value":@(r.value),@"raw":raw}];usleep(100000);
    }
    NSData *data=[NSJSONSerialization dataWithJSONObject:rows options:NSJSONWritingPrettyPrinted error:nil];fwrite(data.bytes,1,data.length,stdout);puts("");gm_ddc_close(s);return 0;
}}
