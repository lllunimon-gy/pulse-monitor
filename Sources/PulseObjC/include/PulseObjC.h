#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
typedef struct { double busySince; int32_t busy; } PLProbeState;

@interface PLBusyInterval : NSObject
@property(nonatomic, readonly) double start;
@property(nonatomic, readonly) double end;
- (instancetype)initWithStart:(double)start end:(double)end;
@end

@interface PLProbeReading : NSObject
@property(nonatomic) double busySince;
@property(nonatomic) BOOL busy;
@property(nonatomic) NSUInteger droppedIntervals;
@property(nonatomic, copy) NSArray<PLBusyInterval *> *completed;
@end

@interface PLRunLoopProbe : NSObject
- (instancetype)initWithThreshold:(double)threshold;
- (void)start;
- (void)stop;
- (void)reset;
- (PLProbeState)snapshot;
/// Atomically drains qualifying completed intervals; capacity is 64.
- (PLProbeReading *)drain;
@end

typedef struct {
    double uptime;
    uint64_t footprintBytes;
    double cpuSeconds;
    int32_t memoryValid;
    int32_t cpuValid;
} PLResourceReading;
FOUNDATION_EXPORT PLResourceReading PLReadResources(void);
FOUNDATION_EXPORT NSString *PLHardwareModel(void);
NS_ASSUME_NONNULL_END
