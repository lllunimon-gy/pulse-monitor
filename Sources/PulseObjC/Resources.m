#import "PulseObjC.h"
#import <mach/mach.h>
#import <sys/resource.h>
#import <sys/sysctl.h>
#import <TargetConditionals.h>

NSString *PLHardwareModel(void) {
#if TARGET_OS_SIMULATOR
    return [@"simulator:" stringByAppendingString:NSProcessInfo.processInfo.environment[@"SIMULATOR_MODEL_IDENTIFIER"] ?: @"unknown"];
#else
    char model[256] = {0};
    size_t size = sizeof(model);
#if TARGET_OS_OSX
    const char *key = "hw.model";
#else
    const char *key = "hw.machine";
#endif
    if (sysctlbyname(key, model, &size, NULL, 0) != 0) return @"unknown";
    model[sizeof(model) - 1] = 0;
    return [NSString stringWithUTF8String:model] ?: @"unknown";
#endif
}

PLResourceReading PLReadResources(void) {
    PLResourceReading result = {0};
    result.uptime = NSProcessInfo.processInfo.systemUptime;
    task_vm_info_data_t info = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t status = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
    if (status == KERN_SUCCESS && count >= TASK_VM_INFO_REV1_COUNT) {
        result.footprintBytes = info.phys_footprint;
        result.memoryValid = YES;
    }
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) == 0) {
        result.cpuSeconds = usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6
                          + usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6;
        result.cpuValid = YES;
    }
    return result;
}
