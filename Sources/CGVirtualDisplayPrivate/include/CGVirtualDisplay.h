// SPDX-License-Identifier: GPL-3.0-or-later
// Apple's private CGVirtualDisplay API (CoreGraphics, macOS 11+). It is not in the SDK headers;
// the classes resolve at runtime from CoreGraphics. Interface as used by DeskPad
// (github.com/Stengo/DeskPad, MIT) and BetterDisplay.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@class CGVirtualDisplay;

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic, nullable) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (nonatomic) CGPoint whitePoint;
@property (copy, nonatomic, nullable) void (^terminationHandler)(id _Nullable, CGVirtualDisplay * _Nullable);
- (void)setDispatchQueue:(dispatch_queue_t)queue;
- (nullable dispatch_queue_t)dispatchQueue;
@end

@interface CGVirtualDisplayMode : NSObject
@property (readonly, nonatomic) unsigned int width;
@property (readonly, nonatomic) unsigned int height;
@property (readonly, nonatomic) double refreshRate;
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) NSArray *modes;
@property (readonly, nonatomic) unsigned int hiDPI;
@property (readonly, nonatomic) CGDirectDisplayID displayID;
@property (readonly, nonatomic, nullable) id terminationHandler;
@property (readonly, nonatomic, nullable) dispatch_queue_t queue;
@property (readonly, nonatomic) unsigned int maxPixelsHigh;
@property (readonly, nonatomic) unsigned int maxPixelsWide;
@property (readonly, nonatomic) unsigned int vendorID;
@property (readonly, nonatomic) unsigned int productID;
@property (readonly, nonatomic) unsigned int serialNum;
@property (readonly, nonatomic) NSString *name;
@property (readonly, nonatomic) CGSize sizeInMillimeters;
- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

NS_ASSUME_NONNULL_END
