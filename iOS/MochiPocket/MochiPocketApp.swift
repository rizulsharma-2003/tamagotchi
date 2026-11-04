import SwiftUI

@main
struct MochiPocketApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var coordinator = ActivityCoordinator.shared
    @State private var link = MacLink.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Start listening at launch, not when the screen appears: iOS also wakes the app in the
        // background to hand over a Live Activity's update address after the Mac starts one.
        ActivityCoordinator.shared.start()
        MacLink.shared.start()
        PhoneWorld.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(coordinator: coordinator, link: link)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: coordinator.animateDemoWhileAway()
            case .active:
                coordinator.stopDemoAnimation()
                coordinator.followMacEnd()
                link.read()
                Task { await PhoneNotifications.shared.refresh() }
                PhoneNotifications.shared.catchUp()
            default: break
            }
        }
    }
}
