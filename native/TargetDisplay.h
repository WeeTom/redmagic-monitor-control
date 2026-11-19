#pragma once

#import <Foundation/Foundation.h>
#import "avservice.h"

static inline NSString *GMConfiguredSerial(void) {
    id serial = [[NSUserDefaults standardUserDefaults] persistentDomainForName:@"com.local.redmagic-display"][@"MonitorSerial"];
    return [serial isKindOfClass:[NSString class]] ? [serial stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : nil;
}

// A duplicate serial is ambiguous, even when both EDIDs claim the same model.
static inline AVServiceInfos *GMFindTarget(AVServiceInfos *infos, int count, NSString *serial) {
    if (!serial.length) return NULL;
    AVServiceInfos *target = NULL;
    for (int i = 0; i < count; i++) {
        AVServiceInfos *candidate = &infos[i];
        if (candidate->edidStatus != kIOReturnSuccess || ![candidate->alphNumSerial isEqualToString:serial]) continue;
        if (target || ![candidate->productName.uppercaseString isEqualToString:@"GM001J"]) return NULL;
        target = candidate;
    }
    return target;
}
