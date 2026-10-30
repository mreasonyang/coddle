import Foundation
import Darwin

/// Called only on the helper's serial power queue. The durable baseline is
/// committed before ON, and retained until restoration is confirmed.
final class SleepLease {
    let journal: String
    let read: () -> Bool?
    let write: (Bool) -> Bool
    let now: () -> TimeInterval
    private var deadline: TimeInterval?
    private var recoveryPending = true

    init(journal: String, read: @escaping () -> Bool?, write: @escaping (Bool) -> Bool,
         now: @escaping () -> TimeInterval) {
        self.journal = journal; self.read = read; self.write = write; self.now = now
    }

    private enum JournalError: Error { case unavailable }

    private func baseline() throws -> Bool? {
        let fd = open(journal, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw JournalError.unavailable
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0, info.st_size <= 32 else {
            throw JournalError.unavailable
        }
        let data = FileHandle(fileDescriptor: fd, closeOnDealloc: false).readDataToEndOfFile()
        switch String(data: data, encoding: .utf8) {
        case "v1 baseline=0\n": return false
        case "v1 baseline=1\n": return true
        default: throw JournalError.unavailable
        }
    }

    private func syncDirectory() throws {
        let directory = (journal as NSString).deletingLastPathComponent
        let fd = open(directory, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw JournalError.unavailable }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw JournalError.unavailable }
    }

    private func save(_ value: Bool) throws {
        var template = Array((journal + ".XXXXXX").utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw JournalError.unavailable }
        let temporary = String(cString: template)
        defer { close(fd); unlink(temporary) }
        let data = Data("v1 baseline=\(value ? 1 : 0)\n".utf8)
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard fchmod(fd, 0o600) == 0, written == data.count, fsync(fd) == 0,
              rename(temporary, journal) == 0 else { throw JournalError.unavailable }
        try syncDirectory()
    }

    /// With no ownership record, OFF (including startup) is a read-only no-op.
    /// A value changed away from our imposed ON is left to its newer owner.
    func release() -> String {
        deadline = nil
        recoveryPending = true
        do {
            guard let original = try baseline() else {
                recoveryPending = false
                return "ok"
            }
            guard let current = read() else { return "err state-unavailable" }
            if !original && current {
                guard write(false), read() == false else { return "err restore-failed" }
            }
            guard unlink(journal) == 0 else { return "err journal-unavailable" }
            try syncDirectory()
            recoveryPending = false
            return "ok"
        } catch { return "err journal-unavailable" }
    }

    func acquire(until expires: TimeInterval) -> String {
        guard now() < expires else { return "err lease-expired" }
        if recoveryPending || deadline.map({ now() >= $0 }) == true {
            guard release() == "ok" else { return "err cleanup-pending" }
        }
        if let active = deadline, active > now() {
            guard read() == true else { return "err state-unconfirmed" }
            deadline = expires
            return "ok"
        }
        guard now() < expires else { return "err lease-expired" }
        guard let original = read() else { return "err state-unavailable" }
        do {
            guard try baseline() == nil else {
                recoveryPending = true
                return "err cleanup-pending"
            }
            try save(original)
        } catch {
            recoveryPending = true
            return "err journal-unavailable"
        }
        deadline = expires
        if !original && !write(true) {
            _ = release()
            return "err enable-failed"
        }
        guard now() < expires else { _ = release(); return "err lease-expired" }
        guard read() == true else { _ = release(); return "err state-unconfirmed" }
        return "ok"
    }

    func reconcile() {
        if recoveryPending || deadline.map({ now() >= $0 }) == true { _ = release() }
    }

    /// Verify our lease and the global flag together; external ON is not ours.
    func status() -> String {
        reconcile()
        guard !recoveryPending else { return "err state-unconfirmed" }
        guard deadline != nil else { return "ok lid=0" }
        return read() == true ? "ok lid=1" : "err state-unconfirmed"
    }
}
