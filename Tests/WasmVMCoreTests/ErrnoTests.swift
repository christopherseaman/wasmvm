import XCTest
@testable import WasmVMCore

final class ErrnoTests: XCTestCase {

    func test_POSIX_ENOENT_maps_to_2() {
        XCTAssertEqual(ErrnoMap.errno(for: POSIXError(.ENOENT)), .ENOENT)
        XCTAssertEqual(LinuxErrno.ENOENT.rawValue, 2)
    }

    func test_POSIX_EACCES_maps_to_13() {
        XCTAssertEqual(ErrnoMap.errno(for: POSIXError(.EACCES)), .EACCES)
        XCTAssertEqual(LinuxErrno.EACCES.rawValue, 13)
    }

    func test_POSIX_EEXIST_maps_to_17() {
        XCTAssertEqual(ErrnoMap.errno(for: POSIXError(.EEXIST)), .EEXIST)
    }

    func test_POSIX_ENOTDIR_maps_to_20() {
        XCTAssertEqual(ErrnoMap.errno(for: POSIXError(.ENOTDIR)), .ENOTDIR)
    }

    func test_POSIX_EISDIR_maps_to_21() {
        XCTAssertEqual(ErrnoMap.errno(for: POSIXError(.EISDIR)), .EISDIR)
    }

    func test_POSIX_EINVAL_maps_to_22() {
        XCTAssertEqual(ErrnoMap.errno(for: POSIXError(.EINVAL)), .EINVAL)
    }

    func test_POSIX_ENOSPC_maps_to_28() {
        XCTAssertEqual(ErrnoMap.errno(for: POSIXError(.ENOSPC)), .ENOSPC)
    }

    func test_POSIX_unknown_code_falls_back_to_EIO() {
        // ECHILD = 10 isn't in our LinuxErrno enum.
        XCTAssertEqual(ErrnoMap.errno(for: POSIXError(.ECHILD)), .EIO)
    }

    func test_NSError_NSFileReadNoPermissionError_maps_to_EACCES() {
        let err = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError, userInfo: nil)
        XCTAssertEqual(ErrnoMap.errno(for: err), .EACCES)
    }

    func test_NSError_NSFileWriteNoPermissionError_maps_to_EACCES() {
        let err = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: nil)
        XCTAssertEqual(ErrnoMap.errno(for: err), .EACCES)
    }

    func test_NSError_NSFileNoSuchFileError_maps_to_ENOENT() {
        let err = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, userInfo: nil)
        XCTAssertEqual(ErrnoMap.errno(for: err), .ENOENT)
    }

    func test_CocoaError_fileReadNoPermission_maps_to_EACCES() {
        XCTAssertEqual(ErrnoMap.errno(for: CocoaError(.fileReadNoPermission)), .EACCES)
    }

    func test_CocoaError_fileWriteNoPermission_maps_to_EACCES() {
        XCTAssertEqual(ErrnoMap.errno(for: CocoaError(.fileWriteNoPermission)), .EACCES)
    }

    func test_CocoaError_fileNoSuchFile_maps_to_ENOENT() {
        XCTAssertEqual(ErrnoMap.errno(for: CocoaError(.fileNoSuchFile)), .ENOENT)
    }

    func test_CocoaError_fileReadNoSuchFile_maps_to_ENOENT() {
        XCTAssertEqual(ErrnoMap.errno(for: CocoaError(.fileReadNoSuchFile)), .ENOENT)
    }

    func test_NSError_with_NSPOSIXErrorDomain_maps_to_posix_code() {
        // EACCES (13) under POSIX domain wrapped as NSError.
        let err = NSError(domain: NSPOSIXErrorDomain, code: 13, userInfo: nil)
        XCTAssertEqual(ErrnoMap.errno(for: err), .EACCES)
    }

    func test_unrelated_error_falls_back_to_EIO() {
        struct CustomError: Error {}
        XCTAssertEqual(ErrnoMap.errno(for: CustomError()), .EIO)
    }

    func test_unrelated_NSError_domain_falls_back_to_EIO() {
        let err = NSError(domain: "com.example.weird", code: 1234, userInfo: nil)
        XCTAssertEqual(ErrnoMap.errno(for: err), .EIO)
    }
}
