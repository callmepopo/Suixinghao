import Foundation

@main struct RecoveryChecks {
    enum Failure: Error { case expected }
    @MainActor static func main() async throws {
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw NSError(domain: label, code: 1) }
            print("通过：" + label)
        }
        let shared = SharedOperation()
        var requests = 0
        var fresh = false
        let first = Task { @MainActor in
            try await shared.run {
                requests += 1
                try await Task.sleep(nanoseconds: 80_000_000)
                fresh = true
            }
        }
        await Task.yield()
        let second = Task { @MainActor in
            try await shared.run { requests += 1 }
            try check(fresh, "并发接听等待新鲜状态，不提前返回")
        }
        try await first.value; try await second.value
        try check(requests == 1 && !shared.isRunning, "启动与来电只发起一次恢复")

        var failureReports = 0
        let failed = Task { @MainActor in
            try await shared.run(onFailure: { _ in failureReports += 1 }) {
                requests += 1
                try await Task.sleep(nanoseconds: 50_000_000)
                throw Failure.expected
            }
        }
        await Task.yield()
        let joined = Task { @MainActor in try await shared.run(onFailure: { _ in failureReports += 1 }) { requests += 1 } }
        var failures = 0
        do { try await failed.value } catch Failure.expected { failures += 1 }
        do { try await joined.value } catch Failure.expected { failures += 1 }
        try check(failures == 2 && requests == 2, "并发恢复共享失败结果")
        try check(failureReports == 1, "共享失败只更新一次连接状态")
        try await shared.run { requests += 1 }
        try check(requests == 3, "网络恢复后允许重新连接")

        let started = Date()
        var cancelled = false
        do {
            try await shared.run(timeout: 50_000_000) {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { cancelled = true; throw error }
            }
            throw Failure.expected
        } catch let error as URLError { try check(error.code == .timedOut, "恢复超时有明确失败结果") }
        try check(cancelled && Date().timeIntervalSince(started) < 1 && !shared.isRunning, "超时取消网络任务并释放恢复状态")

        let old = Task { @MainActor in
            try await shared.run { try await Task.sleep(nanoseconds: 5_000_000_000) }
        }
        await Task.yield()
        shared.cancel()
        let replacement = Task { @MainActor in
            try await shared.run { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        await Task.yield()
        do { try await old.value; throw Failure.expected } catch is CancellationError { }
        try check(shared.isRunning, "取消旧连接不会清除新恢复任务")
        try await replacement.value
        try check(!shared.isRunning, "新恢复完成后正确清理")
    }
}
