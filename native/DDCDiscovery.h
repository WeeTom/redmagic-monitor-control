#pragma once
#import <Foundation/Foundation.h>

/// Enumerates external EDIDs without issuing a DDC/CI command.
NSArray<NSString *> * _Nonnull GMDDCDiscoverSerials(NSInteger * _Nonnull matchedCount);
