import AVFoundation
import Foundation
import Network

/// Pull-based downlink: the hardware asks for samples and the jitter buffer answers,
/// so playback never depends on main-thread completion callbacks.
func makeDownlinkSourceNode(format: AVAudioFormat, jitter: DownlinkJitter) -> AVAudioSourceNode {
    AVAudioSourceNode(format: format) { _, _, frameCount, list -> OSStatus in
        let now = DispatchTime.now().uptimeNanoseconds
        for (index, buffer) in UnsafeMutableAudioBufferListPointer(list).enumerated() {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            if index == 0 {
                jitter.render(into: data, count: Int(frameCount), now: now)
            } else {
                data.update(repeating: 0, count: Int(frameCount))
            }
        }
        return noErr
    }
}

/// Interface kind of the phone's current network (wifi/cellular/...), never names or addresses.
final class CallNetworkMonitor: @unchecked Sendable {
    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "com.junpo.suixinghao.call-network")
    func start(_ report: @escaping @Sendable (String, UInt64) -> Void) {
        stop()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let kind: (String, UInt64)
            if path.status != .satisfied { kind = ("none", 0) }
            else if path.usesInterfaceType(.wifi) { kind = ("wifi", 1) }
            else if path.usesInterfaceType(.cellular) { kind = ("cellular", 2) }
            else if path.usesInterfaceType(.wiredEthernet) { kind = ("wired", 3) }
            else { kind = ("other", 4) }
            report(kind.0, kind.1)
        }
        monitor.start(queue: queue)
        self.monitor = monitor
    }
    func stop() { monitor?.cancel(); monitor = nil }
}
