import Foundation

@main struct AudioRouteChecks {
    static func main() {
        var car = AudioRoutePolicy()
        precondition(car.shouldSelectInitialBluetooth(current: .receiver, available: true))
        precondition(!car.shouldSelectInitialBluetooth(current: .receiver, available: true))
        for route in [AudioRoutePolicy.Output.speaker, .external, .unavailable] {
            var existing = AudioRoutePolicy()
            precondition(!existing.shouldSelectInitialBluetooth(current: route, available: true))
        }
        var manualReceiver = AudioRoutePolicy()
        manualReceiver.selected(.receiver)
        precondition(!manualReceiver.shouldSelectInitialBluetooth(current: .receiver, available: true))

        var lockScreen = AudioRoutePolicy()
        lockScreen.selected(.speaker) // User taps before media/network setup completes.
        precondition(!lockScreen.shouldSelectInitialBluetooth(current: .receiver, available: true))
        precondition(lockScreen.shouldRepairSpeaker(current: .receiver))
        lockScreen.selected(.speaker) // Notification from our repair must not rearm it.
        precondition(!lockScreen.shouldRepairSpeaker(current: .receiver))
        lockScreen.selected(.receiver) // A later system choice always wins.
        precondition(!lockScreen.shouldRepairSpeaker(current: .receiver))
        lockScreen.selected(.speaker)
        lockScreen.deviceChanged(to: .external)
        precondition(!lockScreen.shouldRepairSpeaker(current: .receiver))
        lockScreen.deviceChanged(to: .receiver) // Unplugging never revives an old override.
        precondition(!lockScreen.shouldRepairSpeaker(current: .receiver))
        let newCall = AudioRoutePolicy()
        precondition(newCall.selection == nil)

        // No old microphone callback or queued speech may cross a hardware switch.
        let frames = PCMFrames()
        frames.setState(active: true, muted: false)
        let old = frames.resetCapture()
        frames.append(Data(repeating: 1, count: 320), generation: old)
        let current = frames.resetCapture()
        frames.append(Data(repeating: 2, count: 320), generation: old)
        precondition(frames.next().allSatisfy { $0 == 0 })
        frames.append(Data(repeating: 3, count: 320), generation: current)
        precondition(frames.next().allSatisfy { $0 == 3 })
        frames.setState(active: true, muted: true)
        let muted = frames.resetCapture()
        frames.append(Data(repeating: 4, count: 320), generation: muted)
        precondition(frames.next().allSatisfy { $0 == 0 })
        frames.setState(active: false, muted: false)
        let early = frames.resetCapture()
        frames.append(Data(repeating: 5, count: 320), generation: early)
        precondition(frames.next().allSatisfy { $0 == 0 })
        print("通过：蓝牙初始选择、锁屏免提单次恢复、系统后选优先、设备变化与新通话隔离、旧采音丢弃、静音和接通前保护（离线）")
    }
}
