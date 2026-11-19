#include "GMProtocol.h"
#include <string.h>

enum { BEFORE_READY, BEFORE_WAIT, SET_READY, SETTLE, AFTER_READY, AFTER_WAIT, DONE };
enum { QUERY_TIMEOUT=2200, SET_SETTLE=2000, CONFIRM_GAP=500, BEFORE_LIMIT=3, AFTER_LIMIT=5 };

static void finish(GMState *s, int result) { s->result=result; s->phase=DONE; }
int gm_init(GMState *s, int action, int reapply, uint64_t now) {
    int desired=action==GM_STATUS ? -1 : action;
    int ok=gm_init_feature(s,GM_INPUT,action==GM_TOGGLE ? GM_TYPEC : desired,reapply,now);
    if (action==GM_TOGGLE) s->wanted=GM_TOGGLE;
    s->action=action;
    return ok;
}
int gm_value_valid(int feature,int value,int for_write) {
    switch (feature) {
    case GM_INPUT:return for_write ? (value>=1 && value<=4) : (value>=0 && value<=5);
    case GM_MODE:return value>=0 && value<=7;
    case GM_HDR:return value>=1 && value<=2;
    case GM_LIGHT_POWER:return for_write ? value==1 : (value>=1 && value<=2);
    case GM_LIGHT_COLOR:case GM_LIGHT_EFFECT:return value>=1 && value<=7;
    case GM_LIGHT_LEVEL:return value>=1 && value<=3;
    case GM_FRONT_COLOR:case GM_REAR_COLOR:return value>=1 && value<=6;
    case GM_VOLUME_LAB:return value>=0 && value<=(for_write ? 10 : 100);
    default:return 0;
    }
}
int gm_init_feature(GMState *s,int feature,int desired,int reapply,uint64_t now) {
    memset(s,0,sizeof(*s));
    s->action=desired<0 ? GM_STATUS : desired; s->reapply=!!reapply;
    s->before=s->after=s->wanted=-1; s->due=now; s->expires=now+25000;
    s->feature=feature; s->wanted=desired;
    s->before_limit=feature==GM_VOLUME_LAB ? 1 : BEFORE_LIMIT;
    s->query_head=0xde; s->reply_head=0xce; s->set_head=0xee;
    const int groups[]={1,1,6,1,2,3,4,5,6,2};
    if (feature<GM_INPUT || feature>GM_VOLUME_LAB || desired < -1 ||
        (desired>=0 && !gm_value_valid(feature,desired,1))) {
        finish(s,GM_BAD_ACTION); return 0;
    }
    s->group=groups[feature];
    if (feature==GM_INPUT || feature==GM_VOLUME_LAB) {
        s->query_head=0xdd;s->reply_head=0xcd;s->set_head=0xed;
    } else if (feature==GM_MODE || feature==GM_HDR) {
        s->query_head=0xdc;s->reply_head=0xcc;s->set_head=0xec;
    }
    return 1;
}
int gm_finished(const GMState *s) { return s->phase==DONE; }
int gm_poll(GMState *s, uint64_t now, uint8_t command[3]) {
    if (gm_finished(s)) return 0;
    if (now>=s->expires) { finish(s,GM_TIMEOUT); return 0; }
    if (now<s->due) return 0;
    if (s->phase==BEFORE_WAIT) {
        if (s->stage_queries>=s->before_limit) { finish(s,GM_TIMEOUT); return 0; }
        s->phase=BEFORE_READY;
    } else if (s->phase==AFTER_WAIT) {
        if (s->stage_queries>=AFTER_LIMIT) { finish(s,GM_TIMEOUT); return 0; }
        s->phase=AFTER_READY;
    } else if (s->phase==SETTLE) s->phase=AFTER_READY;
    if (s->phase==SET_READY) {
        command[0]=(uint8_t)s->set_head; command[1]=(uint8_t)s->group; command[2]=(uint8_t)s->wanted;
        s->set_writes++; s->stage_queries=0; s->samples=0;
        s->phase=SETTLE; s->due=now+SET_SETTLE;
        return 1;
    }
    if (s->phase==BEFORE_READY || s->phase==AFTER_READY) {
        if (s->phase==AFTER_READY && s->stage_queries>=AFTER_LIMIT) {
            finish(s,GM_MISMATCH); return 0;
        }
        command[0]=(uint8_t)s->query_head; command[1]=(uint8_t)s->group; command[2]=0;
        s->phase=s->phase==BEFORE_READY ? BEFORE_WAIT : AFTER_WAIT;
        s->query_writes++; s->stage_queries++; s->due=now+QUERY_TIMEOUT;
        return 1;
    }
    return 0;
}
void gm_input_reply(GMState *s, uint8_t value, uint64_t now) {
    if (gm_finished(s) || now>=s->expires || !gm_value_valid(s->feature,value,0) || now>=s->due) return;
    if (s->phase==BEFORE_WAIT) {
        s->before=value; s->after=value;
        if (s->wanted<0) { finish(s,GM_READ); return; }
        if (s->feature==GM_INPUT && s->wanted==GM_TOGGLE)
            s->wanted=value==GM_TYPEC ? GM_DP : GM_TYPEC;
        if (value==s->wanted && !s->reapply) { finish(s,GM_ALREADY); return; }
        s->phase=SET_READY; s->due=now+250;
    } else if (s->phase==AFTER_WAIT) {
        s->after=value;
        s->samples=value==s->wanted ? s->samples+1 : 0;
        if (s->samples>=2) { finish(s,GM_SWITCHED); return; }
        s->phase=AFTER_READY; s->due=now+CONFIRM_GAP;
    }
}
void gm_frame_reply(GMState *s,const uint8_t frame[3],uint64_t now) {
    if (frame[0]==s->reply_head && frame[1]==s->group) gm_input_reply(s,frame[2],now);
}
int gm_reconnect(GMState *s, uint64_t now) {
    if (gm_finished(s) || now>=s->expires || s->reconnects>=1) return 0;
    s->reconnects++; s->samples=0; s->stage_queries=0;
    s->phase=s->set_writes ? AFTER_READY : BEFORE_READY;
    s->due=now+250;
    return 1;
}
const char *gm_result_name(const GMState *s) {
    switch (s->result) {
    case GM_READ:return "input_query_verified";
    case GM_ALREADY:return "already_reported_no_write";
    case GM_SWITCHED:return "input_confirmed_by_two_queries";
    case GM_TIMEOUT:return "query_timeout_unconfirmed";
    case GM_MISMATCH:return "input_readback_mismatch";
    case GM_BAD_ACTION:return "unsupported_action";
    default:return "pending";
    }
}
void gm_decoder_reset(GMDecoder *d) { memset(d,0,sizeof(*d)); }
int gm_decode(GMDecoder *d, const uint8_t *data, size_t length,
              GMFrame *frames, size_t capacity) {
    size_t count=0;
    if (!length || length>60 || d->used>2) { gm_decoder_reset(d); return -1; }
    for (size_t i=0;i<length;i++) {
        d->bytes[d->used++]=data[i];
        uint8_t head=d->bytes[0];
        int group=d->used>=2 ? d->bytes[1] : -1;
        int feature=-1;
        if (head==0xcd) feature=group==1 ? GM_INPUT : group==2 ? GM_VOLUME_LAB : -1;
        if (head==0xcc) feature=group==1 ? GM_MODE : group==6 ? GM_HDR : -1;
        if (head==0xce && group>=1 && group<=6) feature=GM_LIGHT_POWER+group-1;
        if ((head!=0xcd && head!=0xcc && head!=0xce && head!=1 && head!=0) ||
            (d->used>=2 && (head<=1 ? group!=head : feature<0)) ||
            (d->used==3 && (head<=1 ? d->bytes[2]!=head : !gm_value_valid(feature,d->bytes[2],0)))) {
            gm_decoder_reset(d); return -1;
        }
        if (d->used==3) {
            if (count==capacity) { gm_decoder_reset(d); return -1; }
            memcpy(frames[count++].bytes,d->bytes,3); d->used=0;
        }
    }
    return (int)count;
}
