import Foundation
import Darwin

/// Reads per-process statistics through public libproc APIs (`proc_listallpids`, `proc_pidinfo`,
/// `proc_pid_rusage`). Works for processes owned by the current user without any special privileges.
enum ProcessInspector {
    struct ProcessInfoRecord: Sendable {
        var pid: pid_t
        var parentPID: pid_t
        var name: String
        var path: String
    }

    static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBufferPointer { buf in
            proc_listallpids(buf.baseAddress, Int32(buf.count * MemoryLayout<pid_t>.size))
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count))).filter { $0 > 0 }
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard r == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let r = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard r > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Physical footprint (the number Activity Monitor shows as "Memory") in bytes.
    static func physicalFootprint(of pid: pid_t) -> UInt64? {
        var usage = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &usage) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard r == 0 else { return nil }
        return usage.ri_phys_footprint
    }

    /// Builds a pid → parent pid table for the whole system (one pass, cheap).
    static func parentTable() -> [pid_t: pid_t] {
        var table: [pid_t: pid_t] = [:]
        for pid in allPIDs() {
            if let ppid = parentPID(of: pid) { table[pid] = ppid }
        }
        return table
    }

    /// Footprint of each root pid including all of its descendant processes (e.g. browser helpers).
    static func footprintsIncludingDescendants(of roots: [pid_t]) -> [pid_t: UInt64] {
        let parents = parentTable()
        var children: [pid_t: [pid_t]] = [:]
        for (pid, ppid) in parents { children[ppid, default: []].append(pid) }
        var result: [pid_t: UInt64] = [:]
        for root in roots {
            var total: UInt64 = 0
            var stack = [root]
            var seen = Set<pid_t>()
            while let p = stack.popLast() {
                guard seen.insert(p).inserted else { continue }
                total &+= physicalFootprint(of: p) ?? 0
                stack.append(contentsOf: children[p] ?? [])
            }
            result[root] = total
        }
        return result
    }

    /// All processes whose executable is an `ollama` binary (server and model runners).
    static func ollamaProcesses() -> [ProcessInfoRecord] {
        allPIDs().compactMap { pid in
            guard let path = path(of: pid) else { return nil }
            let name = (path as NSString).lastPathComponent
            guard name == "ollama" else { return nil }
            return ProcessInfoRecord(pid: pid, parentPID: parentPID(of: pid) ?? 0, name: name, path: path)
        }
    }

    /// Ancestor chain of a pid (excluding launchd, pid 1).
    static func ancestors(of pid: pid_t, table: [pid_t: pid_t]? = nil) -> [pid_t] {
        let t = table ?? parentTable()
        var chain: [pid_t] = []
        var current = pid
        var guardCount = 0
        while let p = t[current], p > 1, guardCount < 64 {
            chain.append(p)
            current = p
            guardCount += 1
        }
        return chain
    }
}
