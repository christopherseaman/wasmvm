import Foundation

/// Placeholder for future LISTEN/ACCEPT support per `spec/03-net-bridge.md` §"Listen/accept".
/// MVP only implements outbound CONNECT; LISTEN returns CONNECT_ERR upstream.
enum PortAllocator {
    static let isMVPListenSupported = false
}
