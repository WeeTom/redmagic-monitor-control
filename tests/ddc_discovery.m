#import "../native/TargetDisplay.h"
#include <assert.h>

int main(void) { @autoreleasepool {
    AVServiceInfos sinks[] = {
        {.edidStatus = kIOReturnSuccess, .productName = @"GM001J", .alphNumSerial = @"TEST-B"},
        {.edidStatus = kIOReturnSuccess, .productName = @"GM001J", .alphNumSerial = @"TEST-A"},
        {.edidStatus = kIOReturnSuccess, .productName = @"GM001J Pro", .alphNumSerial = @"TEST-X"},
        {.edidStatus = kIOReturnBadMedia, .productName = @"GM001J", .alphNumSerial = @"TEST-A"},
    };
    NSInteger matched;
    assert(GMBindableSerials(NULL, 0, &matched).count == 0 && matched == 0);
    assert([GMBindableSerials(sinks, 1, &matched) isEqual:@[@"TEST-B"]] && matched == 1);
    NSArray *ordered = @[@"TEST-A", @"TEST-B"];
    assert([GMBindableSerials(sinks, 4, &matched) isEqual:ordered] && matched == 2);
    sinks[1].alphNumSerial = @"TEST-B";
    assert(GMBindableSerials(sinks, 4, &matched).count == 0 && matched == 2);
    assert(!GMFindTarget(sinks, 4, @"TEST-B"));
    sinks[1].productName = @"Other";
    assert(GMBindableSerials(sinks, 4, &matched).count == 0 && matched == 1);
    sinks[1].alphNumSerial = @"OTHER";
    sinks[0].alphNumSerial = nil;
    assert(GMBindableSerials(sinks, 4, &matched).count == 0 && matched == 1);
    sinks[0].alphNumSerial = @" TEST";
    assert(GMBindableSerials(sinks, 4, &matched).count == 0 && matched == 1);
    return 0;
} }
