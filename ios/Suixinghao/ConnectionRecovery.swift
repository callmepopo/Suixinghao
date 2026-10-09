import Foundation

/// Pure policy shared by the reconnect worker and local acceptance checks.
enum ConnectionRecovery {
    static func delay(afterFailures count: Int) -> UInt64 {
        UInt64([1, 2, 4, 8, 15][min(max(count - 1, 0), 4)]) * 1_000_000_000
    }
    static func ended(_ status: CallStatus, originalID: String) -> Bool {
        status.available && (!status.hasCall || status.call_id != originalID)
    }
}
