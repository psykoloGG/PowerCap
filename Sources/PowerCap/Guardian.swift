import Darwin
import Foundation
import os

/// A small helper process that watches PowerCap and resumes every limited process when PowerCap
/// exits for any reason, including a crash or force quit. Without it a paused app could stay
/// frozen until someone sent it SIGCONT by hand.
///
/// PowerCap records the processes it limits in a state file before limiting them. The guardian
/// replays that file once PowerCap is gone.
enum Guardian {
    private static let launchArgument = "--guardian"
    private static let logger = Logger(subsystem: "com.psykologg.PowerCap", category: "Guardian")

    private static var stateFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PowerCap", isDirectory: true)
            .appendingPathComponent("limited-processes.json")
    }

    /// Runs the guardian when this process was launched as one. Returns false for a normal launch.
    static func runIfRequested(arguments: [String]) -> Bool {
        guard let argumentIndex = arguments.firstIndex(of: launchArgument),
              argumentIndex + 1 < arguments.count,
              let parentPid = pid_t(arguments[argumentIndex + 1]) else {
            return false
        }
        // "killall PowerCap" should only reach the app. The guardian leaves on its own once the app is gone.
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        waitForExit(of: parentPid)
        releaseRecordedProcesses()
        return true
    }

    static func launch() {
        guard let executableURL = Bundle.main.executableURL else {
            return
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [launchArgument, String(getpid())]
        do {
            try process.run()
        } catch {
            logger.error("Could not start guardian: \(error.localizedDescription)")
        }
    }

    static func record(_ processes: Set<ProcessIdentity>) {
        do {
            if processes.isEmpty {
                if FileManager.default.fileExists(atPath: stateFileURL.path) {
                    try FileManager.default.removeItem(at: stateFileURL)
                }
                return
            }
            try FileManager.default.createDirectory(at: stateFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Array(processes)).write(to: stateFileURL, options: .atomic)
        } catch {
            logger.error("Could not record limited processes: \(error.localizedDescription)")
        }
    }

    /// Resumes and unclamps every recorded process that is still the same process instance.
    static func releaseRecordedProcesses() {
        guard let data = try? Data(contentsOf: stateFileURL) else {
            return
        }
        do {
            let processes = try JSONDecoder().decode([ProcessIdentity].self, from: data)
            for process in processes where ProcessTable.identity(of: process.pid) == process {
                kill(process.pid, SIGCONT)
                Throttler.setEfficiencyCoresOnly(false, pid: process.pid)
            }
            try FileManager.default.removeItem(at: stateFileURL)
        } catch {
            logger.error("Could not release recorded processes: \(error.localizedDescription)")
        }
    }

    private static func waitForExit(of pid: pid_t) {
        let queue = kqueue()
        guard queue >= 0 else {
            return
        }
        defer { close(queue) }

        var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT), fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        // Registration fails when the app already exited, which means it is time to clean up.
        guard kevent(queue, &change, 1, nil, 0, nil) == 0 else {
            return
        }
        var event = kevent()
        while kevent(queue, nil, 0, &event, 1, nil) < 0 && errno == EINTR {}
    }
}
