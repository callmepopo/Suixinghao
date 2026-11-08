import UIKit

/// Hardware differences between iPhone and iPad that change what the app offers.
/// iPad has no cellular calling, no earpiece receiver and no paired Apple Watch; dialing
/// through the service, CallKit incoming calls, SMS and settings are the same on both.
@MainActor
enum DeviceTraits {
    static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    /// Device name for user-facing text ("在 iPhone 设置中…" / "在 iPad 设置中…").
    static var name: String { isPad ? "iPad" : "iPhone" }
    /// "系统拨出" hands the number to the Phone app; only iPhone places cellular calls.
    static var canPlaceCellularCalls: Bool { !isPad }
    /// Built-in earpiece receiver ("iPhone 听筒"); iPad plays calls through its speakers.
    static var hasReceiver: Bool { !isPad }
    /// Apple Watch pairs only with iPhone, so the Watch mirroring reminder is iPhone-only.
    static var mirrorsCallsToWatch: Bool { !isPad }
}
