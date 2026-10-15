#ifndef CSYSTEMPOWER_H
#define CSYSTEMPOWER_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#include <sys/types.h>

// Private IOReport API from libIOReport. It exposes the chip's CPU and GPU energy counters
// without root access, which is how tools like macmon read power on Apple Silicon.
typedef struct IOReportSubscription *IOReportSubscriptionRef;

CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef group, CFStringRef subgroup, uint64_t unused1, uint64_t unused2, uint64_t unused3) CF_RETURNS_RETAINED;
IOReportSubscriptionRef IOReportCreateSubscription(void *unused, CFMutableDictionaryRef desiredChannels, CFMutableDictionaryRef *subscribedChannels, uint64_t channelId, CFTypeRef options);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef subscription, CFMutableDictionaryRef subscribedChannels, CFTypeRef options) CF_RETURNS_RETAINED;
CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef previous, CFDictionaryRef current, CFTypeRef options) CF_RETURNS_RETAINED;
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef channel) CF_RETURNS_NOT_RETAINED;
CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef channel) CF_RETURNS_NOT_RETAINED;
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef channel, int32_t index);

// Private libsystem call that maps helper and XPC processes back to the app responsible for them.
pid_t responsibility_get_pid_responsible_for_pid(pid_t pid);

#endif
