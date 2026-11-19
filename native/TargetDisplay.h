#pragma once

#import <Foundation/Foundation.h>
#import "avservice.h"

static inline NSString *GMConfiguredSerial(void) {
    id serial = [[NSUserDefaults standardUserDefaults] persistentDomainForName:@"com.local.redmagic-display"][@"MonitorSerial"];
    return [serial isKindOfClass:[NSString class]] ? [serial stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : nil;
}

static inline BOOL GMIsTargetModel(const AVServiceInfos *candidate) {
    return candidate->edidStatus == kIOReturnSuccess &&
        [candidate->productName.uppercaseString isEqualToString:@"GM001J"];
}

// A duplicate serial is ambiguous, even when both EDIDs claim the same model.
static inline AVServiceInfos *GMFindTarget(AVServiceInfos *infos, int count, NSString *serial) {
    if (!serial.length) return NULL;
    AVServiceInfos *target = NULL;
    for (int i = 0; i < count; i++) {
        AVServiceInfos *candidate = &infos[i];
        if (candidate->edidStatus != kIOReturnSuccess || ![candidate->alphNumSerial isEqualToString:serial]) continue;
        if (target || !GMIsTargetModel(candidate)) return NULL;
        target = candidate;
    }
    return target;
}

static inline NSArray<NSString *> *GMBindableSerials(AVServiceInfos *infos, int count, NSInteger *matchedCount) {
    NSMutableArray<NSString *> *serials = [NSMutableArray array];
    *matchedCount = 0;
    for (int i = 0; i < count; i++) {
        AVServiceInfos *candidate = &infos[i];
        if (!GMIsTargetModel(candidate)) continue;
        ++*matchedCount;
        NSString *serial = candidate->alphNumSerial;
        // Persisted bindings trim surrounding whitespace. Offer only identities that round-trip.
        if (!serial.length || ![serial isEqualToString:[serial stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet]] ||
            [serial rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) continue;
        if (GMFindTarget(infos, count, serial) == candidate) [serials addObject:serial];
    }
    return [serials sortedArrayUsingSelector:@selector(compare:)];
}
