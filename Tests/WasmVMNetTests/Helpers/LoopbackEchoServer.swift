import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Real loopback TCP echo server using POSIX sockets. Spawns a thread per
/// accepted connection that reads bytes and writes them back until EOF.
/// Used by NetBridge integration tests as the upstream "remote".
final class LoopbackEchoServer {
    private let listenFd: Int32
    let port: UInt16
    private var stopFlag = false
    private let acceptThread: Thread

    init() throws {
        let fd = socket(AF_INET, sockType_STREAM, 0)
        if fd < 0 { throw POSIXError(.EIO) }

        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0   // ephemeral
        addr.sin_addr.s_addr = UInt32(0x7f000001).bigEndian   // 127.0.0.1

        let bindRC = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                bind(fd, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindRC != 0 {
            _ = close(fd)
            throw POSIXError(.EADDRINUSE)
        }

        if listen(fd, 64) != 0 {
            _ = close(fd)
            throw POSIXError(.EIO)
        }

        var bound = sockaddr_in()
        var blen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let portRC = withUnsafeMutablePointer(to: &bound) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                getsockname(fd, sp, &blen)
            }
        }
        if portRC != 0 {
            _ = close(fd)
            throw POSIXError(.EIO)
        }

        self.listenFd = fd
        self.port = UInt16(bigEndian: bound.sin_port)
        let stop = StopFlagBox()
        self.acceptThread = Thread {
            LoopbackEchoServer.acceptLoop(fd: fd, stop: stop)
        }
        self.stopBox = stop
        acceptThread.start()
    }

    private let stopBox: StopFlagBox

    func stop() {
        stopBox.set()
        _ = close(listenFd)
    }

    deinit { stop() }

    private static func acceptLoop(fd: Int32, stop: StopFlagBox) {
        while !stop.isSet {
            var peer = sockaddr_in()
            var plen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let cfd = withUnsafeMutablePointer(to: &peer) { p -> Int32 in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                    accept(fd, sp, &plen)
                }
            }
            if cfd < 0 { return }
            Thread.detachNewThread {
                echoLoop(fd: cfd)
            }
        }
    }

    private static func echoLoop(fd: Int32) {
        let bufLen = 64 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufLen)
        defer {
            buf.deallocate()
            _ = close(fd)
        }
        while true {
            let n = read(fd, buf, bufLen)
            if n <= 0 { return }
            var written = 0
            while written < n {
                let w = write(fd, buf.advanced(by: written), n - written)
                if w <= 0 { return }
                written += w
            }
        }
    }
}

private final class StopFlagBox {
    private let lock = NSLock()
    private var flag = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}

private var sockType_STREAM: Int32 {
    #if canImport(Darwin)
    return SOCK_STREAM
    #else
    return Int32(SOCK_STREAM.rawValue)
    #endif
}
