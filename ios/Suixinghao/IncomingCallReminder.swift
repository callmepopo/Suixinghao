import Foundation
import UserNotifications

@MainActor
protocol ReminderNotificationDelivering {
    func add(_ id: String) async throws
    func remove(_ id: String)
}

@MainActor
private final class SystemReminderNotifications: ReminderNotificationDelivering {
    private let center = UNUserNotificationCenter.current()
    func add(_ id: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = "随行号来电"
        content.body = "请在 iPhone 上接听。"
        content.categoryIdentifier = IncomingCallReminder.category
        content.threadIdentifier = IncomingCallReminder.category
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        try await center.add(request)
    }
    func remove(_ id: String) {
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }
}

@MainActor
final class IncomingCallReminder {
    static let category = "suixinghao.incoming-reminder"
    private let delivery: any ReminderNotificationDelivering
    private var state = IncomingReminderState()
    private func identifier(_ id: String) -> String { Self.category + "." + id }
    init(delivery: (any ReminderNotificationDelivering)? = nil) {
        self.delivery = delivery ?? SystemReminderNotifications()
    }

    func show(_ id: String) async {
        guard state.begin(id) else { return }
        // No caller data, badge or actions. Permission uses the existing notification grant.
        do { try await delivery.add(identifier(id)) }
        catch { _ = state.clear(id); return }
        // Ending/answering may race the asynchronous add operation.
        if state.active != id { remove(id) }
    }

    func clear(_ id: String) {
        _ = state.clear(id)
        remove(id)
    }

    private func remove(_ id: String) {
        delivery.remove(identifier(id))
    }
}
