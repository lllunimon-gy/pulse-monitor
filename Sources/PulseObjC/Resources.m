#import "PulseObjC.h"
#import <mach/mach.h>
#import <sys/resource.h>

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
