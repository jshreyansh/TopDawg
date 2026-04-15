import Foundation
import Darwin

// `PROC_PIDPATHINFO_MAXSIZE` lives in <libproc.h> and isn't always re-exported by the
// Swift Darwin module. It's defined as `4 * MAXPATHLEN` (4 * 1024) in Apple's headers.
private let kProcPidPathInfoMaxSize: Int = 4 * 1024

/// Read-only process introspection used to decide whether a session is "still alive"
/// and to walk parent-process chains so we can find the terminal window owning a CLI
/// session.
enum ProcessProbe {

    /// Cheap liveness check — sending signal 0 to a PID returns success if the process
    /// exists and we have permission to signal it (true for our own user's processes).
    static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        let result = kill(pid, 0)
        if result == 0 { return true }
        // EPERM means the process exists but we can't signal it — still "alive".
        return errno == EPERM
    }

    /// Returns the parent PID for a given PID using `sysctl(KERN_PROC_PID)`.
    /// Used to walk up from a `claude` process to the owning terminal app.
    static func parentPID(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = mib.withUnsafeMutableBufferPointer { buf -> Int32 in
            sysctl(buf.baseAddress, u_int(buf.count), &info, &size, nil, 0)
        }
        guard result == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    /// Walks up the parent chain (max `maxDepth` hops) and returns the first ancestor
    /// PID whose executable name matches one of the known terminal bundle identifiers
    /// or process names. Used by `WindowFocuser` to bring a terminal forward.
    static func owningTerminalPID(for pid: Int32, maxDepth: Int = 8) -> Int32? {
        var current: Int32? = pid
        var depth = 0
        while let p = current, depth < maxDepth {
            if let name = executableName(of: p), TerminalIdentifiers.matches(name) {
                return p
            }
            current = parentPID(of: p)
            depth += 1
        }
        return nil
    }

    /// Returns the executable name (last path component of argv[0]) for a PID.
    static func executableName(of pid: Int32) -> String? {
        var path = [CChar](repeating: 0, count: kProcPidPathInfoMaxSize)
        let len = proc_pidpath(pid, &path, UInt32(path.count))
        guard len > 0 else { return nil }
        let full = String(cString: path)
        return (full as NSString).lastPathComponent
    }
}

/// Known macOS terminal apps — we walk parent chains looking for one of these.
enum TerminalIdentifiers {
    static let names: Set<String> = [
        "Terminal",
        "iTerm2",
        "iTerm",
        "Ghostty",
        "WezTerm",
        "Alacritty",
        "Warp",
        "Hyper",
        "kitty",
        "Tabby",
        "Code",          // VS Code integrated terminal
        "Code Helper",
        "Cursor",
        "Cursor Helper",
        "Windsurf",
    ]
    static func matches(_ executableName: String) -> Bool {
        names.contains(executableName)
    }
}
