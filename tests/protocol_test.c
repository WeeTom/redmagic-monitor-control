#include "../core/GMProtocol.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static unsigned checks=0;
#define CHECK(x) do { checks++; assert(x); } while (0)
static void next(GMState *s,uint64_t t,int a,int b,int c) {
    uint8_t cmd[3]={0}; CHECK(gm_poll(s,t,cmd));
    CHECK(cmd[0]==a && cmd[1]==b && cmd[2]==c);
}
static GMState start(int action,int input,int force) {
    GMState s; CHECK(gm_init(&s,action,force,0));
    next(&s,0,0xdd,1,0);gm_input_reply(&s,(uint8_t)input,10);return s;
}
int main(void) {
    uint8_t cmd[3]; GMState s;
    for (int action=0;action<256;action++) {
        int valid=action==0 || action==1 || action==2 || action==3 || action==4 || action==100;
        CHECK(gm_init(&s,action,0,0)==valid);
        if (!valid) { CHECK(gm_finished(&s));CHECK(!gm_poll(&s,0,cmd)); }
    }
    for (int current=0;current<=5;current++) {
        s=start(0,current,0); CHECK(s.result==GM_READ && s.after==current && s.set_writes==0);
        const int actions[]={1,2,3,4,100};
        for (size_t a=0;a<sizeof(actions)/sizeof(actions[0]);a++) {
            int target=actions[a]==100 ? (current==1 ? 2 : 1) : actions[a];
            s=start(actions[a],current,0);
            if (current==target) { CHECK(s.result==GM_ALREADY && s.set_writes==0);continue; }
            CHECK(!gm_poll(&s,259,cmd));next(&s,260,0xed,1,target);
            gm_input_reply(&s,(uint8_t)target,261); CHECK(!gm_finished(&s)); /* unsolicited response */
            CHECK(!gm_poll(&s,2259,cmd));next(&s,2260,0xdd,1,0);
            gm_input_reply(&s,(uint8_t)target,2270);CHECK(!gm_finished(&s));
            gm_input_reply(&s,(uint8_t)target,2271);CHECK(!gm_finished(&s)); /* duplicate */
            next(&s,2770,0xdd,1,0);gm_input_reply(&s,(uint8_t)target,2780);
            CHECK(s.result==GM_SWITCHED && s.set_writes==1 && s.samples==2);
        }
    }
    s=start(1,1,1);next(&s,260,0xed,1,1);CHECK(s.set_writes==1); /* explicit reapply */
    CHECK(gm_reconnect(&s,500));CHECK(!gm_reconnect(&s,501));
    next(&s,750,0xdd,1,0);gm_input_reply(&s,1,760);
    next(&s,1260,0xdd,1,0);gm_input_reply(&s,1,1270);
    CHECK(s.result==GM_SWITCHED && s.set_writes==1); /* verify, never repeat set */
    s=start(2,1,0);next(&s,260,0xed,1,2);
    for (unsigned i=0;i<5;i++) {
        next(&s,2260+i*510,0xdd,1,0);gm_input_reply(&s,1,2270+i*510);
    }
    CHECK(!gm_poll(&s,4810,cmd));CHECK(s.result==GM_MISMATCH && s.set_writes==1);
    CHECK(gm_init(&s,2,0,0));
    next(&s,0,0xdd,1,0);next(&s,2200,0xdd,1,0);next(&s,4400,0xdd,1,0);
    CHECK(!gm_poll(&s,6600,cmd));CHECK(s.result==GM_TIMEOUT && s.set_writes==0);
    CHECK(gm_init(&s,2,0,0));next(&s,0,0xdd,1,0);
    gm_input_reply(&s,2,2200);CHECK(!gm_finished(&s)); /* expired reply */
    CHECK(!gm_poll(&s,25000,cmd));CHECK(s.result==GM_TIMEOUT);
    GMDecoder d; GMFrame frames[20];
    const uint8_t packet[]={1,1,1,0xcd,1,2,0,0,0};
    for (size_t split=1;split<sizeof(packet);split++) {
        gm_decoder_reset(&d);
        int a=gm_decode(&d,packet,split,frames,20);CHECK(a>=0);
        int b=gm_decode(&d,packet+split,sizeof(packet)-split,frames+a,20-(size_t)a);
        CHECK(a+b==3 && d.used==0);
        CHECK(memcmp(frames[1].bytes,packet+3,3)==0);
    }
    for (unsigned v=0;v<256;v++) {
        uint8_t msg[]={0xcd,1,(uint8_t)v};gm_decoder_reset(&d);
        CHECK(gm_decode(&d,msg,3,frames,20)==(v<=5 ? 1 : -1));
    }
    const uint8_t invalid[]={0xed,1,2,0xcd,1,2};gm_decoder_reset(&d);
    CHECK(gm_decode(&d,invalid,sizeof(invalid),frames,20)==-1); /* no byte-search false reply */
    CHECK(gm_decode(&d,packet,sizeof(packet),frames,1)==-1);
    CHECK(gm_init_feature(&s,GM_VOLUME_LAB,0,0,0));
    next(&s,0,0xdd,2,0);CHECK(!gm_poll(&s,2200,cmd));
    CHECK(s.result==GM_TIMEOUT && s.set_writes==0); /* stock firmware: zero audio writes */
    CHECK(gm_init_feature(&s,GM_LIGHT_POWER,2,0,0)==0); /* unsupported stock setter */
    for (int f=GM_INPUT;f<=GM_VOLUME_LAB;f++) {
        for (int v=0;v<=255;v++) {
            int valid=gm_value_valid(f,v,1);
            CHECK(gm_init_feature(&s,f,v,0,0)==valid);
            if (!valid) { CHECK(gm_finished(&s));continue; }
            next(&s,0,s.query_head,s.group,0);
            uint8_t ack[]={1,1,1};gm_frame_reply(&s,ack,10);
            CHECK(s.before==-1 && s.set_writes==0); /* ACK cannot authorise a write */
            uint8_t reply[]={(uint8_t)s.reply_head,(uint8_t)s.group,(uint8_t)v};
            gm_frame_reply(&s,reply,10);
            CHECK(s.result==GM_ALREADY && s.set_writes==0);
        }
    }
    printf("PASS: %u checks; no hardware contacted\n",checks);
    return 0;
}
