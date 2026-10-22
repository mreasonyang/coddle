import Foundation
import Darwin

/// Small synchronous dependencies used only by background hardware workers.
/// I/O and system probes use monotonic whole-operation deadlines. Explicit
/// administrator authorization remains pending until its script actually exits.
enum BoundedIO {
    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    static func ready(_ fd: Int32, events: Int16, until deadline: TimeInterval) -> Bool {
        while now < deadline {
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(max(1, min(100, (deadline - now) * 1000))))
            if result > 0 { return descriptor.revents & (events | Int16(POLLHUP)) != 0 }
            if result < 0 && errno != EINTR { return false }
        }
        return false
    }

    static func nonblocking(_ fd: Int32) { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }

    static func readLine(_ fd: Int32, until deadline: TimeInterval, maxBytes: Int = 4096) -> String? {
        var bytes = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 512)
        while ready(fd, events: Int16(POLLIN), until: deadline) {
            let count = read(fd, &chunk, chunk.count)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { return nil }
            for byte in chunk.prefix(count) {
                if byte == 10 { return String(bytes: bytes, encoding: .utf8) }
                guard bytes.count < maxBytes else { return nil }
                bytes.append(byte)
            }
        }
        // An unterminated or overlong command is never executed.
        return nil
    }

    static func writeLine(_ fd: Int32, _ line: String, until deadline: TimeInterval) -> Bool {
        let bytes = Array((line + "\n").utf8)
        var offset = 0
        while offset < bytes.count && ready(fd, events: Int16(POLLOUT), until: deadline) {
            let count = bytes.withUnsafeBytes { raw in
                send(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset, MSG_NOSIGNAL)
            }
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { return false }
            offset += count
        }
        return offset == bytes.count
    }

    static func run(_ executable: String, arguments: [String], timeout: TimeInterval?) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "spawn failed: \(error.localizedDescription)") }
        try? pipe.fileHandleForWriting.close()
        let fd = pipe.fileHandleForReading.fileDescriptor
        nonblocking(fd)
        defer { try? pipe.fileHandleForReading.close() }
        let deadline = timeout.map { now + $0 } ?? .infinity
        var output = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        var timedOut = false
        while true {
            let count = read(fd, &bytes, bytes.count)
            if count > 0 {
                if output.count < 65_536 { output.append(contentsOf: bytes.prefix(min(count, 65_536 - output.count))) }
            }
            if !process.isRunning && count <= 0 { break }
            if now >= deadline {
                timedOut = true
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            if count <= 0 { Thread.sleep(forTimeInterval: 0.005) }
        }
        if timedOut {
            // Reap the killed process before releasing the serialized writer.
            // A finite wait also covers a pathological uninterruptible child.
            guard exited.wait(timeout: .now() + 2) == .success else {
                return (-2, "process termination could not be confirmed")
            }
            return (-1, "process timed out")
        }
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
}
