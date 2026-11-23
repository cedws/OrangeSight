import SwiftUI

@main
struct OrangeSightApp: App {
    @State private var session = SessionStore()
    @State private var settings = AppSettings()
    @State private var readStore = ReadStore()
    @State private var notifier = Notifier()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(settings)
                .environment(readStore)
                .environment(notifier)
                .tint(.hnOrange)
                .task { await session.restore() }
        }
    }
}

struct RootView: View {
    enum TabID: Hashable { case stories, account, settings, search }

    @Environment(SessionStore.self) private var session
    @Environment(Notifier.self) private var notifier
    @State private var tab: TabID = .stories

    var body: some View {
        @Bindable var notifier = notifier
        TabView(selection: $tab) {
            Tab("Stories", systemImage: "newspaper", value: .stories) {
                FeedTab()
            }
            Tab("Account", systemImage: "person.crop.circle", value: .account) {
                AccountTab()
            }
            Tab("Settings", systemImage: "gearshape", value: .settings) {
                SettingsTab()
            }
            Tab(value: .search, role: .search) {
                SearchTab()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .overlay(alignment: .top) {
            if let toast = notifier.toast {
                ToastView(toast: toast)
                    .padding(.top, 8)
            }
        }
        .sheet(isPresented: $notifier.signInRequested) {
            SignInSheet()
        }
    }
}
