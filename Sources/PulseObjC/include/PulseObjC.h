#import <Foundation/Foundation.h>
typedef struct { double busySince; int32_t busy; } PLProbeState;
NS_ASSUME_NONNULL_BEGIN
@interface PLRunLoopProbe : NSObject
- (void)start;
- (void)stop;
- (void)reset;
- (PLProbeState)snapshot;
@end
NS_ASSUME_NONNULL_END
