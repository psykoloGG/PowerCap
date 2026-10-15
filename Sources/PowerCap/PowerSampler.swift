import CSystemPower
import Foundation
import IOKit

struct PowerSample {
    /// Estimated watts per app pid. Only filled when hasPowerReadings is true.
    var appWatts: [pid_t: Double] = [:]
    var appProcesses: [pid_t: [ProcessIdentity]] = [:]
    var cpuWatts = 0.0
    var gpuWatts = 0.0
    /// False for the very first measurement, which only sets the baseline, and for samples
    /// that only refreshed which processes belong to which app.
    var hasPowerReadings = false
}

/// Measures how much power each app draws. CPU energy comes straight from the kernel's
/// per-process energy counters. The GPU only reports energy for the whole chip, so each app
/// gets a part of it based on how much GPU time its processes used.
///
/// Not thread safe. PowerController only calls it from its sampler queue.
final class PowerSampler: @unchecked Sendable {
    private let chipEnergy = ChipEnergyCounters()
    private var previousProcessEnergy: [ProcessIdentity: UInt64] = [:]
    private var previousGpuTime: [UInt64: UInt64] = [:]
    private var previousSampleTime: UInt64 = 0

    /// Groups user processes by app. When measuresPower is false it skips the energy readings,
    /// which keeps the frequent refreshes for limited apps cheap.
    func sample(appPids: Set<pid_t>, measuresPower: Bool) -> PowerSample {
        let processes = ProcessTable.currentUserProcesses()
        var appProcesses: [pid_t: [ProcessIdentity]] = [:]
        var owningApp: [pid_t: pid_t] = [:]
        for (pid, record) in processes {
            guard let appPid = ProcessTable.owningApp(of: pid, appPids: appPids, processes: processes) else {
                continue
            }
            appProcesses[appPid, default: []].append(record.identity)
            owningApp[pid] = appPid
        }

        var sample = PowerSample(appProcesses: appProcesses)
        guard measuresPower else {
            return sample
        }

        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let isBaseline = previousSampleTime == 0
        let elapsedSeconds = Double(now - previousSampleTime) / 1e9
        previousSampleTime = now

        let cpuJoules = measureCpuEnergy(appProcesses)
        let gpuShares = measureGpuShares(owningApp: owningApp, isBaseline: isBaseline)
        let chip = chipEnergy.readDelta()
        guard !isBaseline, elapsedSeconds > 0 else {
            return sample
        }

        sample.hasPowerReadings = true
        sample.cpuWatts = chip.cpuJoules / elapsedSeconds
        sample.gpuWatts = chip.gpuJoules / elapsedSeconds
        for appPid in appProcesses.keys {
            let appJoules = cpuJoules[appPid, default: 0] + chip.gpuJoules * gpuShares[appPid, default: 0]
            sample.appWatts[appPid] = appJoules / elapsedSeconds
        }
        return sample
    }

    /// Returns the joules each app used on the CPU since the previous sample.
    private func measureCpuEnergy(_ appProcesses: [pid_t: [ProcessIdentity]]) -> [pid_t: Double] {
        var currentEnergy: [ProcessIdentity: UInt64] = [:]
        var joulesByApp: [pid_t: Double] = [:]
        for (appPid, identities) in appProcesses {
            for identity in identities {
                guard let energy = Self.energyNanojoules(of: identity.pid) else {
                    continue
                }
                currentEnergy[identity] = energy
                if let previous = previousProcessEnergy[identity], energy >= previous {
                    joulesByApp[appPid, default: 0] += Double(energy - previous) / 1e9
                }
            }
        }
        previousProcessEnergy = currentEnergy
        return joulesByApp
    }

    /// Returns each app's fraction of all GPU time used since the previous sample.
    private func measureGpuShares(owningApp: [pid_t: pid_t], isBaseline: Bool) -> [pid_t: Double] {
        var currentGpuTime: [UInt64: UInt64] = [:]
        var gpuTimeByApp: [pid_t: UInt64] = [:]
        var totalGpuTime: UInt64 = 0
        for client in GpuClients.read() {
            currentGpuTime[client.registryId] = client.gpuNanoseconds
            let delta: UInt64
            if let previous = previousGpuTime[client.registryId] {
                delta = client.gpuNanoseconds >= previous ? client.gpuNanoseconds - previous : 0
            } else {
                // A client that appeared since the last sample did all of its GPU work in this interval.
                delta = isBaseline ? 0 : client.gpuNanoseconds
            }
            totalGpuTime += delta
            if let appPid = owningApp[client.pid] {
                gpuTimeByApp[appPid, default: 0] += delta
            }
        }
        previousGpuTime = currentGpuTime

        guard totalGpuTime > 0 else {
            return [:]
        }
        return gpuTimeByApp.mapValues { Double($0) / Double(totalGpuTime) }
    }

    private static func energyNanojoules(of pid: pid_t) -> UInt64? {
        var usage = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPointer in
                proc_pid_rusage(pid, RUSAGE_INFO_V6, reboundPointer)
            }
        }
        return result == 0 ? usage.ri_energy_nj : nil
    }
}

/// Reads per-process GPU time from the GPU driver's user clients, the same data Activity
/// Monitor shows in its GPU column.
private enum GpuClients {
    struct Client {
        let registryId: UInt64
        let pid: pid_t
        let gpuNanoseconds: UInt64
    }

    static func read() -> [Client] {
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accelerators) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(accelerators) }

        var clients: [Client] = []
        while case let accelerator = IOIteratorNext(accelerators), accelerator != 0 {
            defer { IOObjectRelease(accelerator) }
            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &children) == KERN_SUCCESS else {
                continue
            }
            defer { IOObjectRelease(children) }
            while case let child = IOIteratorNext(children), child != 0 {
                defer { IOObjectRelease(child) }
                if let client = client(from: child) {
                    clients.append(client)
                }
            }
        }
        return clients
    }

    private static func client(from entry: io_registry_entry_t) -> Client? {
        guard let creator = property("IOUserClientCreator", of: entry) as? String,
              let pid = parsePid(fromCreator: creator),
              let usage = property("AppUsage", of: entry) as? [[String: Any]] else {
            return nil
        }
        let gpuNanoseconds = usage.reduce(UInt64(0)) { total, apiUsage in
            total + ((apiUsage["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0)
        }
        var registryId: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &registryId)
        return Client(registryId: registryId, pid: pid, gpuNanoseconds: gpuNanoseconds)
    }

    private static func property(_ key: String, of entry: io_registry_entry_t) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// The creator string looks like "pid 167, WindowServer".
    private static func parsePid(fromCreator creator: String) -> pid_t? {
        guard creator.hasPrefix("pid "), let pidText = creator.dropFirst(4).split(separator: ",").first else {
            return nil
        }
        return pid_t(pidText)
    }
}

/// Whole-chip CPU and GPU energy counters from the IOReport "Energy Model" group.
private final class ChipEnergyCounters {
    private let subscription: IOReportSubscriptionRef?
    private let subscribedChannels: CFMutableDictionary?
    private var previousSample: CFDictionary?

    init() {
        guard let channels = IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0),
              let desiredChannels = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, channels) else {
            subscription = nil
            subscribedChannels = nil
            return
        }
        var subscribed: Unmanaged<CFMutableDictionary>?
        subscription = IOReportCreateSubscription(nil, desiredChannels, &subscribed, 0, nil)
        subscribedChannels = subscribed?.takeRetainedValue()
    }

    /// Returns the joules the CPU and GPU used since the previous call. The first call returns zero.
    func readDelta() -> (cpuJoules: Double, gpuJoules: Double) {
        guard let subscription, let subscribedChannels,
              let currentSample = IOReportCreateSamples(subscription, subscribedChannels, nil) else {
            return (0, 0)
        }
        defer { previousSample = currentSample }

        guard let previousSample,
              let delta = IOReportCreateSamplesDelta(previousSample, currentSample, nil),
              let channels = (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary] else {
            return (0, 0)
        }

        var cpuJoules = 0.0
        var gpuJoules = 0.0
        for channel in channels {
            let channelRef = channel as CFDictionary
            guard let name = IOReportChannelGetChannelName(channelRef), let unit = IOReportChannelGetUnitLabel(channelRef) else {
                continue
            }
            let joules = Self.joules(IOReportSimpleGetIntegerValue(channelRef, 0), unit: unit as String)
            switch name as String {
            case "CPU Energy":
                cpuJoules = joules
            case "GPU Energy":
                gpuJoules = joules
            default:
                continue
            }
        }
        return (cpuJoules, gpuJoules)
    }

    private static func joules(_ value: Int64, unit: String) -> Double {
        switch unit.trimmingCharacters(in: .whitespaces) {
        case "mJ":
            return Double(value) / 1e3
        case "uJ":
            return Double(value) / 1e6
        case "nJ":
            return Double(value) / 1e9
        default:
            return 0
        }
    }
}
