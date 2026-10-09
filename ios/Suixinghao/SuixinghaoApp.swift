import SwiftUI
import Intents

@main
struct SuixinghaoApp: App {
    @UIApplicationDelegateAdaptor(SMSNotifications.self) private var notifications
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--preview-history") {
                NavigationStack { ConnectionHistoryView() }.environment(model).task { await model.startup() }
            } else {
                appRoot
            }
            #else
            appRoot
            #endif
        }
    }
    private var appRoot: some View {
            RootView().environment(model).privacySensitive()
                .task { notifications.model = model }
                .onOpenURL { url in
                    #if DEBUG
                    model.externalCallRoute = "收到 URL：" + (url.scheme ?? "无协议")
                    print("Suixinghao incoming URL route: \(url.scheme ?? "none")")
                    #endif
                    do { model.acceptExternalCall(try API.numberFromSystemCallURL(url)) }
                    catch { model.notice = error.localizedDescription }
                }
                .onContinueUserActivity(INStartCallIntentIdentifier, perform: acceptCallActivity)
                .onContinueUserActivity(INStartAudioCallIntentIdentifier, perform: acceptCallActivity)
                .onContinueUserActivity(INStartVideoCallIntentIdentifier, perform: acceptCallActivity)
    }

    private func acceptCallActivity(_ activity: NSUserActivity) {
        #if DEBUG
        model.externalCallRoute = "收到系统活动：" + activity.activityType
        #endif
        let intent = activity.interaction?.intent
        let number = (intent as? INStartCallIntent)?.contacts?.first?.personHandle?.value
            ?? (intent as? INStartAudioCallIntent)?.contacts?.first?.personHandle?.value
            ?? (intent as? INStartVideoCallIntent)?.contacts?.first?.personHandle?.value
        if let number { model.acceptExternalCall(number) }
    }
}
