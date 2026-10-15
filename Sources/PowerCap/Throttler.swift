import Darwin
import Foundation

/// Applies power limits to app processes.
///
/// A run share below 100% is enforced by pausing the app's processes (SIGSTOP) and resuming
/// them (SIGCONT) in short cycles, so an app at 20% only runs for 10 ms out of every 50 ms.
/// While paused an app can't use the CPU or queue new GPU work, so both drop together.
///
/// "Efficiency cores only" puts the processes in the Darwin background band, which keeps
/// them on the E-cores and also throttles their disk and network access.
final class Throttler {
    struct Target {
        var processes: [ProcessIdentity]
        var runShare: Double
        var efficiencyCoresOnly: Bool

        var isDutyCycled: Bool { runShare < 1.0 }
    }

    private static let cycleNanoseconds: UInt64 = 50_000_000

    private let condition = NSCondition()
    private var targets: [pid_t: Target] = [:]
    private var efficiencyCorePids: Set<pid_t> = []

    init() {
        let thread = Thread { [unowned self] in
            self.runCycles()
        }
        thread.name = "PowerCap.Throttler"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Replaces every target, keyed by app pid. Processes that lose their limit are resumed
    /// and released from the efficiency cores right away.
    func update(_ newTargets: [pid_t: Target]) {
        condition.lock()
        defer { condition.unlock() }

        let pausedPids = Self.pids(in: targets, where: \.isDutyCycled)
        let stillPausedPids = Self.pids(in: newTargets, where: \.isDutyCycled)
        for pid in pausedPids.subtracting(stillPausedPids) {
            kill(pid, SIGCONT)
        }

        let clampedPids = Self.pids(in: newTargets, where: \.efficiencyCoresOnly)
        for pid in efficiencyCorePids.subtracting(clampedPids) {
            Self.setEfficiencyCoresOnly(false, pid: pid)
        }
        for pid in clampedPids.subtracting(efficiencyCorePids) {
            Self.setEfficiencyCoresOnly(true, pid: pid)
        }
        efficiencyCorePids = clampedPids

        targets = newTargets
        condition.signal()
    }

    func releaseAll() {
        update([:])
    }

    private func runCycles() {
        while true {
            condition.lock()
            while !targets.values.contains(where: \.isDutyCycled) {
                condition.wait()
            }
            // Resume everything at the start of a cycle, then pause each app once its share is used up.
            let schedule = targets
                .filter { $0.value.isDutyCycled }
                .map { (appPid: $0.key, runShare: $0.value.runShare) }
                .sorted { $0.runShare < $1.runShare }
            for target in targets.values where target.isDutyCycled {
                Self.send(SIGCONT, to: target)
            }
            condition.unlock()

            let cycleStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            for entry in schedule {
                Self.sleep(until: cycleStart + UInt64(entry.runShare * Double(Self.cycleNanoseconds)))
                // Re-check under the lock so a limit removed mid-cycle never pauses the app again.
                condition.lock()
                if let target = targets[entry.appPid], target.isDutyCycled {
                    Self.send(SIGSTOP, to: target)
                }
                condition.unlock()
            }
            Self.sleep(until: cycleStart + Self.cycleNanoseconds)
        }
    }

    private static func pids(in targets: [pid_t: Target], where include: (Target) -> Bool) -> Set<pid_t> {
        Set(targets.values.filter(include).flatMap { $0.processes.map(\.pid) })
    }

    private static func send(_ signal: Int32, to target: Target) {
        for process in target.processes {
            kill(process.pid, signal)
        }
    }

    static func setEfficiencyCoresOnly(_ enabled: Bool, pid: pid_t) {
        setpriority(PRIO_DARWIN_PROCESS, id_t(pid), enabled ? PRIO_DARWIN_BG : 0)
    }

    private static func sleep(until deadline: UInt64) {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        guard deadline > now else {
            return
        }
        let remaining = deadline - now
        var request = timespec(tv_sec: Int(remaining / 1_000_000_000), tv_nsec: Int(remaining % 1_000_000_000))
        nanosleep(&request, nil)
    }
}
