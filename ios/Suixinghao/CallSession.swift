import Foundation

/// One system call at a time; UUID guards all asynchronous work after cancellation.
struct CallSession {
    struct Call {
        let uuid: UUID
        var remoteID: String?
        let number: String?
        var waitingForAudio = false
        var mediaStarted = false
        var connectedReported = false
        var isOutgoing: Bool { number != nil }
    }
    private(set) var call: Call?

    mutating func outgoing(number: String) -> UUID? {
        guard call == nil else { return nil }
        let uuid = UUID()
        call = Call(uuid: uuid, remoteID: nil, number: number)
        return uuid
    }
    mutating func incoming(id: String) -> UUID? {
        if let call { return call.remoteID == id ? call.uuid : nil }
        let uuid = UUID()
        call = Call(uuid: uuid, remoteID: id, number: nil)
        return uuid
    }
    func contains(_ uuid: UUID) -> Bool { call?.uuid == uuid }
    mutating func waitForAudio(_ uuid: UUID) -> Bool {
        guard contains(uuid), call?.mediaStarted == false, call?.waitingForAudio == false else { return false }
        call?.waitingForAudio = true
        return true
    }
    mutating func takeAudioWork() -> Call? {
        guard call?.waitingForAudio == true else { return nil }
        call?.waitingForAudio = false
        call?.mediaStarted = true
        return call
    }
    mutating func bind(_ id: String, to uuid: UUID) -> Bool {
        guard contains(uuid) else { return false }
        call?.remoteID = id
        return true
    }
    mutating func connected(_ id: String) -> UUID? {
        guard call?.isOutgoing == true, call?.remoteID == id,
              call?.connectedReported == false else { return nil }
        call?.connectedReported = true
        return call?.uuid
    }
    @discardableResult mutating func clear(_ uuid: UUID) -> Call? {
        guard contains(uuid) else { return nil }
        defer { call = nil }
        return call
    }
}
