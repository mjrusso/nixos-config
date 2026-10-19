import Foundation
import OpenDirectory

do {
    guard CommandLine.arguments.count == 2,
          let password = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8),
          !password.isEmpty else {
        exit(EXIT_FAILURE)
    }
    let node = try ODNode(session: ODSession.default(), name: "/Local/Default")
    let record = try node.record(withRecordType: kODRecordTypeUsers,
                                 name: CommandLine.arguments[1], attributes: nil)
    try record.verifyPassword(password)
} catch {
    // Directory errors can include authentication details; report only failure.
    exit(EXIT_FAILURE)
}
