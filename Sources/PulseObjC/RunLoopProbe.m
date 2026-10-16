#import "PulseObjC.h"
#import <CoreFoundation/CoreFoundation.h>
#import <os/lock.h>

@implementation PLBusyInterval
- (instancetype)initWithStart:(double)start end:(double)end {
    if ((self = [super init])) { _start = start; _end = end; }
    return self;
}
@end
@implementation PLProbeReading
@end

@implementation PLRunLoopProbe {
    CFRunLoopObserverRef _observer;
    os_unfair_lock _lock;
    PLProbeState _state;
    double _threshold;
    double _starts[64], _ends[64];
    NSUInteger _next, _count, _dropped;
}
- (instancetype)init { return [self initWithThreshold:0.25]; }
- (instancetype)initWithThreshold:(double)threshold {
    if ((self = [super init])) {
        _lock = (os_unfair_lock){0};
        _state = (PLProbeState){0, 0};
        _threshold = threshold;
    }
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
    double now = NSProcessInfo.processInfo.systemUptime;
    os_unfair_lock_lock(&_lock);
    if (activity == kCFRunLoopBeforeWaiting || activity == kCFRunLoopExit) {
        if (_state.busy && now - _state.busySince >= _threshold) {
            _starts[_next] = _state.busySince;
            _ends[_next] = now;
            _next = (_next + 1) % 64;
            if (_count == 64) _dropped++; else _count++;
        }
        _state.busy = 0;
    } else if (!_state.busy) {
        _state.busy = 1;
        _state.busySince = now;
    }
    os_unfair_lock_unlock(&_lock);
}
- (PLProbeState)snapshot {
    os_unfair_lock_lock(&_lock);
    PLProbeState state = _state;
    os_unfair_lock_unlock(&_lock);
    return state;
}
- (PLProbeReading *)drain {
    double starts[64], ends[64];
    os_unfair_lock_lock(&_lock);
    PLProbeState state = _state;
    NSUInteger count = _count, dropped = _dropped;
    NSUInteger first = (_next + 64 - count) % 64;
    for (NSUInteger i = 0; i < count; i++) {
        starts[i] = _starts[(first + i) % 64];
        ends[i] = _ends[(first + i) % 64];
    }
    _count = 0; _dropped = 0;
    os_unfair_lock_unlock(&_lock);
    PLProbeReading *reading = [PLProbeReading new];
    reading.busy = state.busy != 0;
    reading.busySince = state.busySince;
    reading.droppedIntervals = dropped;
    NSMutableArray *intervals = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        [intervals addObject:[[PLBusyInterval alloc] initWithStart:starts[i] end:ends[i]]];
    }
    reading.completed = intervals;
    return reading;
}
- (void)reset {
    os_unfair_lock_lock(&_lock);
    _state = (PLProbeState){0, 0};
    _next = _count = _dropped = 0;
    os_unfair_lock_unlock(&_lock);
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
