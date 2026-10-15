import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import os

/// One app row in the panel.
struct AppPower: Identifiable {
    let id: pid_t
    let name: String
    let icon: NSImage
    let watts: Double
    let limit: AppLimit
}

private struct RunningApp {
    let pid: pid_t
    let limitKey: String
    let name: String
    let icon: NSImage
}

/// Samples app power in the background, keeps the panel rows current, and turns saved limits
/// into throttling targets.
@MainActor
final class PowerController: ObservableObject {
    @Published private(set) var rows: [AppPower] = []
    @Published private(set) var cpuWatts = 0.0
    @Published private(set) var gpuWatts = 0.0
    @Published private(set) var hasActiveLimits = false
    @Published private(set) var hasSavedLimits = false

    private static let maxRows = 8
    private static let openSampleInterval: TimeInterval = 1
    private static let closedSampleInterval: TimeInterval = 2
    // While the panel is closed, power is only measured every fifth tick (10 s). That keeps
    // PowerCap itself cheap while the ranking stays ready for the next time the panel opens.
    private static let closedTicksPerMeasurement = 5
    // Pausing these would make the whole desktop feel frozen.
    private static let protectedBundleIds: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.loginwindow",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.WindowManager",
    ]

    private let sampler = PowerSampler()
    private let samplerQueue = DispatchQueue(label: "PowerCap.Sampler", qos: .utility)
    private let throttler = Throttler()
    private let limitStore = LimitStore()
    private let logger = Logger(subsystem: "com.psykologg.PowerCap", category: "Controller")

    private var runningApps: [pid_t: RunningApp] = [:]
    private var appProcesses: [pid_t: [ProcessIdentity]] = [:]
    private var smoothedWatts: [pid_t: Double] = [:]
    private var displayOrder: [pid_t] = []
    private var needsRanking = true
    private var guardedProcesses: Set<ProcessIdentity> = []
    private var isPanelOpen = false
    private var isSampling = false
    private var closedTicksSinceMeasurement = 0
    private var sampleTimer: Timer?
    private var launchObserver: NSObjectProtocol?

    init() {
        hasSavedLimits = limitStore.hasLimits
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.appDidLaunch()
            }
        }
        scheduleSampling()
        sampleNow(measuresPower: true)
    }

    var opensAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.error("Could not change login item: \(error.localizedDescription)")
        }
        objectWillChange.send()
    }

    func panelDidOpen() {
        guard !isPanelOpen else {
            return
        }
        isPanelOpen = true
        // Show the last known ranking right away, then rank once more when the fresh measurement
        // lands a few milliseconds later. After that, rows stay put so they don't move under the cursor.
        refreshRunningApps()
        needsRanking = true
        refreshRows()
        needsRanking = true
        scheduleSampling()
        sampleNow(measuresPower: true)
    }

    func panelDidClose() {
        guard isPanelOpen else {
            return
        }
        isPanelOpen = false
        scheduleSampling()
    }

    func setRunShare(_ runShare: Double, for pid: pid_t) {
        updateLimit(for: pid) { $0.runShare = runShare }
    }

    func toggleEfficiencyCores(for pid: pid_t) {
        updateLimit(for: pid) { $0.efficiencyCoresOnly.toggle() }
    }

    func removeAllLimits() {
        limitStore.removeAll()
        hasSavedLimits = false
        applyLimits()
        refreshRows()
    }

    /// Resumes every paused process. Called when PowerCap quits.
    func shutdown() {
        sampleTimer?.invalidate()
        throttler.releaseAll()
        Guardian.record([])
    }

    private func updateLimit(for pid: pid_t, change: (inout AppLimit) -> Void) {
        guard let app = runningApps[pid] else {
            return
        }
        var limit = limitStore.limit(for: app.limitKey)
        change(&limit)
        limitStore.setLimit(limit, for: app.limitKey)
        hasSavedLimits = limitStore.hasLimits
        applyLimits()
        refreshRows()
    }

    private func scheduleSampling() {
        sampleTimer?.invalidate()
        let interval = isPanelOpen ? Self.openSampleInterval : Self.closedSampleInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        timer.tolerance = interval * 0.2
        // Common mode keeps sampling while a slider is being dragged.
        RunLoop.main.add(timer, forMode: .common)
        sampleTimer = timer
    }

    private func tick() {
        if isPanelOpen {
            sampleNow(measuresPower: true)
            return
        }
        closedTicksSinceMeasurement += 1
        if closedTicksSinceMeasurement >= Self.closedTicksPerMeasurement {
            sampleNow(measuresPower: true)
        } else if hasActiveLimits {
            // Limited apps can start new helper processes at any time, so keep their process lists fresh.
            sampleNow(measuresPower: false)
        }
    }

    /// Applies a saved limit as soon as its app launches instead of waiting for the next tick.
    private func appDidLaunch() {
        guard hasSavedLimits else {
            return
        }
        sampleNow(measuresPower: false)
    }

    private func sampleNow(measuresPower: Bool) {
        guard !isSampling else {
            return
        }
        isSampling = true
        if measuresPower {
            closedTicksSinceMeasurement = 0
        }
        refreshRunningApps()
        let appPids = Set(runningApps.keys)
        let sampler = sampler
        samplerQueue.async { [weak self] in
            let sample = sampler.sample(appPids: appPids, measuresPower: measuresPower)
            Task { @MainActor in
                self?.apply(sample)
            }
        }
    }

    private func apply(_ sample: PowerSample) {
        isSampling = false
        appProcesses = sample.appProcesses
        if sample.hasPowerReadings {
            var smoothed: [pid_t: Double] = [:]
            for (pid, watts) in sample.appWatts {
                // Light smoothing so numbers and ranking don't jump every second.
                smoothed[pid] = smoothedWatts[pid].map { $0 * 0.5 + watts * 0.5 } ?? watts
            }
            smoothedWatts = smoothed
        }
        applyLimits()

        guard isPanelOpen else {
            return
        }
        if sample.hasPowerReadings {
            cpuWatts = sample.cpuWatts
            gpuWatts = sample.gpuWatts
        }
        refreshRows()
    }

    private func refreshRunningApps() {
        let ownPid = getpid()
        var currentApps: [pid_t: RunningApp] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isTerminated {
            let pid = app.processIdentifier
            if pid == ownPid || Self.protectedBundleIds.contains(app.bundleIdentifier ?? "") {
                continue
            }
            currentApps[pid] = runningApps[pid] ?? RunningApp(
                pid: pid,
                limitKey: app.bundleIdentifier ?? app.bundleURL?.path ?? app.executableURL?.path ?? "pid:\(pid)",
                name: app.localizedName ?? "Unknown App",
                icon: app.icon ?? NSWorkspace.shared.icon(for: .application)
            )
        }
        runningApps = currentApps
    }

    private func applyLimits() {
        var targets: [pid_t: Throttler.Target] = [:]
        for (pid, app) in runningApps {
            let limit = limitStore.limit(for: app.limitKey)
            guard limit.isActive else {
                continue
            }
            let processes = appProcesses[pid] ?? ProcessTable.identity(of: pid).map { [$0] } ?? []
            targets[pid] = Throttler.Target(processes: processes, runShare: limit.runShare, efficiencyCoresOnly: limit.efficiencyCoresOnly)
        }

        // The guardian file must cover every process that could be paused at any moment, so new
        // processes are recorded before limiting and released ones are dropped only afterwards.
        let limitedProcesses = Set(targets.values.flatMap(\.processes))
        let coveredProcesses = guardedProcesses.union(limitedProcesses)
        if coveredProcesses != guardedProcesses {
            Guardian.record(coveredProcesses)
        }
        throttler.update(targets)
        if limitedProcesses != coveredProcesses {
            Guardian.record(limitedProcesses)
        }
        guardedProcesses = limitedProcesses

        if hasActiveLimits != !targets.isEmpty {
            hasActiveLimits = !targets.isEmpty
        }
    }

    private func refreshRows() {
        if needsRanking {
            displayOrder = rankedApps()
            needsRanking = smoothedWatts.isEmpty
        }
        displayOrder.removeAll { runningApps[$0] == nil }
        rows = displayOrder.compactMap { pid in
            guard let app = runningApps[pid] else {
                return nil
            }
            return AppPower(id: pid, name: app.name, icon: app.icon, watts: smoothedWatts[pid] ?? 0, limit: limitStore.limit(for: app.limitKey))
        }
    }

    /// Limited apps come first so they stay reachable while their limit keeps their power low,
    /// followed by the hungriest of the rest.
    private func rankedApps() -> [pid_t] {
        let byPower = runningApps.values.sorted { first, second in
            let firstWatts = smoothedWatts[first.pid] ?? 0
            let secondWatts = smoothedWatts[second.pid] ?? 0
            if firstWatts != secondWatts {
                return firstWatts > secondWatts
            }
            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }
        let limited = byPower.filter { limitStore.limit(for: $0.limitKey).isActive }
        let others = byPower.filter { !limitStore.limit(for: $0.limitKey).isActive }
        return (limited + others).prefix(max(Self.maxRows, limited.count)).map(\.pid)
    }
}
