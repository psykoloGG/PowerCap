import CSystemPower
import Darwin

/// One specific process instance. The start time protects against acting on a reused pid.
struct ProcessIdentity: Hashable, Codable {
    let pid: pid_t
    let startTime: UInt64
}

struct ProcessRecord {
    let identity: ProcessIdentity
    let parentPid: pid_t
}

enum ProcessTable {
    /// Lists every process owned by the current user.
    static func currentUserProcesses() -> [pid_t: ProcessRecord] {
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount > 0 else {
            return [:]
        }

        var pids = [pid_t](repeating: 0, count: Int(estimatedCount) + 64)
        let pidCount = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.stride))
        }
        guard pidCount > 0 else {
            return [:]
        }

        let userId = getuid()
        var records: [pid_t: ProcessRecord] = [:]
        records.reserveCapacity(Int(pidCount))
        for pid in pids.prefix(Int(pidCount)) where pid > 0 {
            guard let info = bsdInfo(of: pid), info.pbi_uid == userId else {
                continue
            }
            records[pid] = ProcessRecord(identity: identity(from: info, pid: pid), parentPid: pid_t(info.pbi_ppid))
        }
        return records
    }

    /// Returns the identity of a live process, or nil when the pid no longer exists.
    static func identity(of pid: pid_t) -> ProcessIdentity? {
        bsdInfo(of: pid).map { identity(from: $0, pid: pid) }
    }

    /// Finds the app a process belongs to. macOS tracks a "responsible" process for helpers and
    /// XPC services, which covers browser renderers and web views. Anything the app spawned
    /// directly, like Unreal's shader compile workers, is caught by walking up the parent chain.
    static func owningApp(of pid: pid_t, appPids: Set<pid_t>, processes: [pid_t: ProcessRecord]) -> pid_t? {
        let responsiblePid = responsibility_get_pid_responsible_for_pid(pid)
        if appPids.contains(responsiblePid) {
            return responsiblePid
        }

        var currentPid = pid
        for _ in 0..<32 {
            if appPids.contains(currentPid) {
                return currentPid
            }
            guard let parentPid = processes[currentPid]?.parentPid, parentPid > 1 else {
                return nil
            }
            currentPid = parentPid
        }
        return nil
    }

    private static func bsdInfo(of pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return nil
        }
        return info
    }

    private static func identity(from info: proc_bsdinfo, pid: pid_t) -> ProcessIdentity {
        ProcessIdentity(pid: pid, startTime: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
    }
}
