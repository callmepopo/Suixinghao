import SwiftUI
import UserNotifications
import Intents

@MainActor
final class SMSNotifications: NSObject, UIApplicationDelegate, @preconcurrency INStartCallIntentHandling, @preconcurrency UNUserNotificationCenterDelegate {
    weak var model: AppModel? {
        didSet {
            if let token { Task { await model?.smsPushTokenUpdated(token) } }
            if pendingOpen {
                pendingOpen = false
                model?.openSMSFromNotification = true
                Task { await model?.refresh() }
            }
            if let pendingCallNumber {
                self.pendingCallNumber = nil
                model?.acceptExternalCall(pendingCallNumber)
            }
        }
    }
    private(set) var token: String?
    private var pendingOpen = false
    private var pendingCallNumber: String?

    private func acceptCallNumber(_ number: String) {
        if let model { model.acceptExternalCall(number) }
        else { pendingCallNumber = number }
    }

    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        guard intent is INStartCallIntent else { return nil }
        #if DEBUG
        model?.externalCallRoute = "收到系统拨号意图"
        #endif
        return self
    }

    func handle(intent: INStartCallIntent, completion: @escaping (INStartCallIntentResponse) -> Void) {
        guard let number = intent.contacts?.first?.personHandle?.value, !number.isEmpty else {
            #if DEBUG
            model?.externalCallRoute = "收到拨号意图，但没有号码"
            #endif
            completion(INStartCallIntentResponse(code: .failure, userActivity: nil))
            return
        }
        acceptCallNumber(number)
        completion(INStartCallIntentResponse(code: .continueInApp, userActivity: nil))
    }


    func application(_ application: UIApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        #if DEBUG
        model?.externalCallRoute = "收到 App 代理呼叫活动"
        #endif
        let intent = userActivity.interaction?.intent
        guard let number = (intent as? INStartCallIntent)?.contacts?.first?.personHandle?.value
            ?? (intent as? INStartAudioCallIntent)?.contacts?.first?.personHandle?.value
            ?? (intent as? INStartVideoCallIntent)?.contacts?.first?.personHandle?.value else { return false }
        acceptCallNumber(number)
        return true
    }

    func application(_ application: UIApplication, open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        #if DEBUG
        model?.externalCallRoute = "收到 App 代理 URL：" + (url.scheme ?? "无协议")
        #endif
        guard let number = try? API.numberFromSystemCallURL(url) else { return false }
        acceptCallNumber(number)
        return true
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let value = deviceToken.map { String(format: "%02x", $0) }.joined()
        token = value
        Task { await model?.smsPushTokenUpdated(value) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        model?.smsNotificationState = "通知注册暂不可用，请稍后重试"
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { await model?.refresh() }
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        Task {
            if let model {
                model.openSMSFromNotification = true
                await model.refresh()
            } else {
                pendingOpen = true
            }
            completionHandler()
        }
    }
}
