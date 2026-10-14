import Foundation

/// Per-call intent only. Device names and identifiers never leave memory.
struct AudioRoutePolicy {
    enum Output: Equatable { case receiver, speaker, external, unavailable }
    private(set) var selection: Output?
    private var initialBluetoothPending = true
    private var speakerRepairAvailable = false

    mutating func selected(_ output: Output) {
        guard output != .unavailable else { return }
        if selection != output { speakerRepairAvailable = output == .speaker }
        selection = output
        initialBluetoothPending = false
    }

    mutating func deviceChanged(to output: Output) {
        selection = output == .unavailable ? nil : output
        initialBluetoothPending = false
        speakerRepairAvailable = false
    }

    mutating func shouldSelectInitialBluetooth(current: Output, available: Bool) -> Bool {
        defer { initialBluetoothPending = false }
        return initialBluetoothPending && selection == nil && current == .receiver && available
    }

    /// A temporary speaker override can be lost during an engine reconfiguration.
    /// Never fight a later system selection, a headset insertion, or retry forever.
    mutating func shouldRepairSpeaker(current: Output) -> Bool {
        guard selection == .speaker, current == .receiver, speakerRepairAvailable else { return false }
        speakerRepairAvailable = false
        return true
    }
}

struct CallAudioRoute: Identifiable, Equatable {
    let id: String
    let name: String
    let symbol: String
}
