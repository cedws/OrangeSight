import SwiftUI

struct SettingsTab: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SessionStore.self) private var session

    var body: some View {
        @Bindable var settings = settings
        RoutedStack {
            Form {
                Section("Feed") {
                    Picker("Default Feed", selection: $settings.defaultFeed) {
                        ForEach(FeedKind.allCases) { feed in
                            Label(feed.title, systemImage: feed.systemImage).tag(feed)
                        }
                    }
                    Toggle("Show Rank Numbers", isOn: $settings.showRank)
                    Toggle("Dim Stories You've Opened", isOn: $settings.dimReadStories)
                }

                Section {
                    Toggle("Open Links in App", isOn: $settings.openLinksInApp)
                    Toggle("Use Reader When Available", isOn: $settings.readerMode)
                        .disabled(!settings.openLinksInApp)
                } header: {
                    Text("Links")
                } footer: {
                    Text("Links to Hacker News items and users always open inside the app.")
                }

                Section("Comments") {
                    Toggle("Tap to Collapse", isOn: $settings.collapseOnTap)
                }

                Section("Account") {
                    LabeledContent("Signed In As", value: session.username ?? "Not signed in")
                    if let karma = session.karma {
                        LabeledContent("Karma", value: karma.formatted())
                    }
                }

                Section("Hacker News") {
                    Link(destination: HNClient.url("newsguidelines.html")) {
                        Label("Guidelines", systemImage: "list.bullet.rectangle")
                    }
                    Link(destination: HNClient.url("newsfaq.html")) {
                        Label("FAQ", systemImage: "questionmark.circle")
                    }
                    Link(destination: URL(string: "https://github.com/HackerNews/API")!) {
                        Label("API", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
