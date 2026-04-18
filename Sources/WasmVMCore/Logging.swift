import Foundation
#if canImport(os)
import os

/// Shared os.Logger subsystem for the entire app.
/// Use category strings to distinguish components in Console.app / `log stream`.
public enum Log {
    public static let subsystem = "com.wasmvm"

    public static let net      = Logger(subsystem: subsystem, category: "net")
    public static let ninep    = Logger(subsystem: subsystem, category: "ninep")
    public static let server   = Logger(subsystem: subsystem, category: "server")
    public static let app      = Logger(subsystem: subsystem, category: "app")
    public static let codec    = Logger(subsystem: subsystem, category: "codec")
}
#else
// Stub for non-Apple platforms (Linux validation): we keep the same call sites
// (`Log.net.debug("...")`) compiling without dragging in os.Logger.
public enum Log {
    public struct StubLogger {
        public func debug(_ message: @autoclosure () -> String) {}
        public func info(_ message: @autoclosure () -> String) {}
        public func notice(_ message: @autoclosure () -> String) {}
        public func warning(_ message: @autoclosure () -> String) {}
        public func error(_ message: @autoclosure () -> String) {}
        public func fault(_ message: @autoclosure () -> String) {}
    }
    public static let net    = StubLogger()
    public static let ninep  = StubLogger()
    public static let server = StubLogger()
    public static let app    = StubLogger()
    public static let codec  = StubLogger()
}
#endif
