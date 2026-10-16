#import "PulseObjC.h"
#import <CoreFoundation/CoreFoundation.h>
#import <os/lock.h>
@implementation PLRunLoopProbe {
    CFRunLoopObserverRef _observer;
    os_unfair_lock _lock;
    PLProbeState _state;
}
- (instancetype)init {
    if ((self = [super init])) { _lock = (os_unfair_lock){0}; _state = (PLProbeState){0,0}; }
    return self;
}
- (void)start {
    if (_observer) return;
    __weak PLRunLoopProbe *weakSelf = self;
    _observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, kCFRunLoopAllActivities, true, 0,
        ^(CFRunLoopObserverRef observer, CFRunLoopActivity activity) {
            [weakSelf observeActivity:activity];
        });
    CFRunLoopAddObserver(CFRunLoopGetMain(), _observer, kCFRunLoopCommonModes);
}
- (void)observeActivity:(CFRunLoopActivity)activity {
    os_unfair_lock_lock(&_lock);
    if (activity == kCFRunLoopBeforeWaiting || activity == kCFRunLoopExit) {
        _state.busy = 0;
    } else if (!_state.busy) {
        _state.busy = 1;
        _state.busySince = NSProcessInfo.processInfo.systemUptime;
    }
    os_unfair_lock_unlock(&_lock);
}
- (PLProbeState)snapshot {
    os_unfair_lock_lock(&_lock); PLProbeState value = _state; os_unfair_lock_unlock(&_lock); return value;
}
- (void)reset {
    os_unfair_lock_lock(&_lock); _state = (PLProbeState){0,0}; os_unfair_lock_unlock(&_lock);
}
- (void)stop {
    if (_observer) {
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), _observer, kCFRunLoopCommonModes);
        CFRelease(_observer); _observer = NULL;
    }
    [self reset];
}
- (void)dealloc { [self stop]; }
@end
