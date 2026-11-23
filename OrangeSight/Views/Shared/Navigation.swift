import SafariServices
import SwiftUI

enum Route: Hashable {
    case thread(Int)
    /// A story thread scrolled to (and highlighting) one of its comments.
    case threadFocus(story: Int, comment: Int)
    case user(String)
    case stories(StoryListSource)
    case comments(CommentListSource)

    /// Recognises news.ycombinator.com links so they open inside the app.
    init?(hnURL url: URL) {
        guard let host = url.host(), host == "news.ycombinator.com" || host == "ycombinator.com" && url.path().hasPrefix("/item") else { return nil }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let id = query.first { $0.name == "id" }?.value
        switch url.path() {
        case "/item":
            guard let id = id.flatMap(Int.init) else { return nil }
            if let focus = url.fragment().flatMap(Int.init) {
                self = .threadFocus(story: id, comment: focus)
            } else {
                self = .thread(id)
            }
        case "/user": guard let id else { return nil }; self = .user(id)
        case "/submitted": guard let id else { return nil }; self = .stories(.submitted(user: id))
        case "/threads": guard let id else { return nil }; self = .comments(.threads(user: id))
        case "/news", "/", "": self = .stories(.feed(.top))
        case "/newest": self = .stories(.feed(.new))
        case "/ask": self = .stories(.feed(.ask))
        case "/show": self = .stories(.feed(.show))
        case "/jobs": self = .stories(.feed(.jobs))
        case "/best": self = .stories(.feed(.best))
        default: return nil
        }
    }
}

/// A NavigationStack that knows every route in the app and intercepts link taps:
/// HN links push in-app, web links open in the in-app browser (or Safari, per Settings).
struct RoutedStack<Root: View>: View {
    @ViewBuilder var root: () -> Root

    @Environment(AppSettings.self) private var settings
    @State private var path = NavigationPath()
    @State private var browserURL: IdentifiedURL?

    var body: some View {
        NavigationStack(path: $path) {
            root()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .thread(let id): ThreadView(id: id)
                    case .threadFocus(let story, let comment): ThreadView(id: story, focus: comment)
                    case .user(let name): UserView(username: name)
                    case .stories(let source): StoryListView(source: source)
                    case .comments(let source): CommentListView(source: source)
                    }
                }
        }
        .environment(\.openURL, OpenURLAction { url in
            if let route = Route(hnURL: url) {
                path.append(route)
                return .handled
            }
            if settings.openLinksInApp, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                browserURL = IdentifiedURL(url: url)
                return .handled
            }
            return .systemAction
        })
        .fullScreenCover(item: $browserURL) { item in
            SafariView(url: item.url, readerMode: settings.readerMode)
                .ignoresSafeArea()
        }
    }
}

struct IdentifiedURL: Identifiable {
    let url: URL
    var id: URL { url }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    let readerMode: Bool

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = readerMode
        config.barCollapsingEnabled = true
        let controller = SFSafariViewController(url: url, configuration: config)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

// MARK: - Formatting

extension Date {
    /// "now", "5m", "3h", "2d", "4mo", "6y"
    var hnAge: String {
        let seconds = max(0, -timeIntervalSinceNow)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(86_400 * 30): return "\(Int(seconds / 86_400))d"
        case ..<(86_400 * 365): return "\(Int(seconds / (86_400 * 30)))mo"
        default: return "\(Int(seconds / (86_400 * 365)))y"
        }
    }
}

extension Int {
    var compact: String {
        self >= 10_000 ? formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) : formatted()
    }
}

// MARK: - Toast

struct ToastView: View {
    let toast: Notifier.Toast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Label(toast.message, systemImage: toast.systemImage)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 24)
            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - Loading states

struct LoadingRow: View {
    var body: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .padding(.vertical, 12)
        .listRowSeparator(.hidden)
    }
}

struct ErrorView: View {
    let error: any Error
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't Load", systemImage: "wifi.exclamationmark")
        } description: {
            Text(error.localizedDescription)
        } actions: {
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
        }
    }
}
