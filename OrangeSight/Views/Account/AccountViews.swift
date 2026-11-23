import SwiftUI
import WebKit

// MARK: - Account tab

struct AccountTab: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        RoutedStack {
            if let username = session.username {
                UserView(username: username)
            } else {
                SignInView()
                    .navigationTitle("Account")
            }
        }
    }
}

// MARK: - Profile

struct UserView: View {
    let username: String

    @Environment(SessionStore.self) private var session
    @State private var profile: UserProfile?
    @State private var error: (any Error)?
    @State private var confirmingSignOut = false
    @State private var showingSubmit = false

    private var isMe: Bool { session.username == username }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        Text(username.prefix(1).uppercased())
                            .font(.title.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .background(Color.hnOrange.gradient, in: .circle)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(username).font(.title2.weight(.semibold))
                            if let profile {
                                Text("Joined \(profile.created.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let profile {
                            VStack(alignment: .trailing) {
                                Text(profile.karma.formatted())
                                    .font(.title3.weight(.semibold).monospacedDigit())
                                Text("karma").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let about = profile?.about, !about.characters.isEmpty {
                        Text(about)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 6)
            }

            Section("Activity") {
                if isMe {
                    Button { showingSubmit = true } label: {
                        Label("Submit a Story", systemImage: "square.and.pencil")
                    }
                }
                NavigationLink(value: Route.stories(.submitted(user: username))) {
                    Label("Submissions", systemImage: "doc.text")
                }
                NavigationLink(value: Route.comments(.byUser(username))) {
                    Label("Comments", systemImage: "bubble.left")
                }
                NavigationLink(value: Route.comments(.threads(user: username))) {
                    Label("Threads", systemImage: "bubble.left.and.bubble.right")
                }
            }

            Section("Favorites") {
                NavigationLink(value: Route.stories(.favorites(user: username))) {
                    Label("Favorite Stories", systemImage: "star")
                }
                NavigationLink(value: Route.comments(.favorites(user: username))) {
                    Label("Favorite Comments", systemImage: "star.bubble")
                }
            }

            if isMe {
                Section("Private") {
                    NavigationLink(value: Route.stories(.upvoted(user: username))) {
                        Label("Upvoted Stories", systemImage: "arrow.up.circle")
                    }
                    NavigationLink(value: Route.comments(.upvoted(user: username))) {
                        Label("Upvoted Comments", systemImage: "arrow.up.message")
                    }
                    NavigationLink(value: Route.stories(.hidden(user: username))) {
                        Label("Hidden Stories", systemImage: "eye.slash")
                    }
                }
                Section {
                    Button("Sign Out", role: .destructive) { confirmingSignOut = true }
                }
            }

            if let error {
                Section { Text(error.localizedDescription).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(isMe ? "Account" : username)
        .toolbar {
            if isMe {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Submit a Story", systemImage: "square.and.pencil") { showingSubmit = true }
                }
            }
        }
        .sheet(isPresented: $showingSubmit) { SubmitView() }
        .refreshable { await load() }
        .task { if profile == nil { await load() } }
        .confirmationDialog("Sign out of Hacker News?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await session.signOut() } }
        }
    }

    private func load() async {
        do {
            profile = try await HNClient.shared.user(username)
            error = nil
            if isMe { await session.refresh() }
        } catch {
            self.error = error
        }
    }
}

// MARK: - Comment lists

@Observable
final class CommentListModel {
    let source: CommentListSource
    var comments: [Comment] = []
    private(set) var parents: [Int: ParentPreview] = [:]
    private(set) var isLoading = false
    private(set) var error: (any Error)?
    private var cursor: PageCursor?
    private var reachedEnd = false

    init(source: CommentListSource) { self.source = source }

    func parent(of comment: Comment) -> ParentPreview? {
        comment.parentID.flatMap { parents[$0] }
    }

    /// Parents of top-level comments that are other comments (replies to the story itself
    /// already show the story title).
    private func loadParents(for page: [Comment]) async {
        let ids = page
            .filter { $0.depth == 0 }
            .compactMap { c in c.parentID.flatMap { $0 != c.storyID && parents[$0] == nil ? $0 : nil } }
        let fetched = await HNClient.shared.parentPreviews(for: Array(Set(ids)))
        parents.merge(fetched) { _, new in new }
    }

    func refresh() async {
        cursor = nil
        reachedEnd = false
        await load(replacing: true)
    }

    func loadMoreIfNeeded(after comment: Comment) async {
        guard !reachedEnd, !isLoading, comment.id == comments.last?.id else { return }
        await load(replacing: false)
    }

    private func load(replacing: Bool) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await HNClient.shared.comments(source, cursor: cursor)
            if replacing {
                comments = page.comments
            } else {
                let existing = Set(comments.map(\.id))
                comments += page.comments.filter { !existing.contains($0.id) }
            }
            cursor = page.next
            reachedEnd = page.next == nil
            error = nil
            await loadParents(for: page.comments)
        } catch is CancellationError {
        } catch {
            if comments.isEmpty || replacing { self.error = error }
        }
    }
}

struct CommentListView: View {
    @State private var model: CommentListModel

    init(source: CommentListSource) {
        _model = State(initialValue: CommentListModel(source: source))
    }

    var body: some View {
        List {
            ForEach($model.comments) { $comment in
                CommentRow(comment: $comment, showsContext: true, replyingTo: model.parent(of: comment))
                .task { await model.loadMoreIfNeeded(after: comment) }
            }
            if model.isLoading && !model.comments.isEmpty { LoadingRow() }
        }
        .listStyle(.plain)
        .environment(\.commentTapOpensThread, true)
        .overlay {
            if model.comments.isEmpty {
                if model.isLoading {
                    ProgressView()
                } else if let error = model.error {
                    ErrorView(error: error) { Task { await model.refresh() } }
                } else {
                    ContentUnavailableView("No Comments", systemImage: "bubble.left")
                }
            }
        }
        .refreshable { await model.refresh() }
        .task { if model.comments.isEmpty { await model.refresh() } }
        .navigationTitle(model.source.title)
    }
}

extension EnvironmentValues {
    /// In flat comment lists a tap opens the comment's thread instead of collapsing it.
    @Entry var commentTapOpensThread = false
}

// MARK: - Sign in

struct SignInView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    var isSheet = false

    @State private var username = ""
    @State private var password = ""
    @State private var creating = false
    @State private var isWorking = false
    @State private var error: (any Error)?
    @State private var showingWebSignIn = false
    @FocusState private var field: Field?

    enum Field { case username, password }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 48))
                        .foregroundStyle(Color.hnOrange)
                    Text(creating ? "Create a Hacker News account" : "Sign in to vote, comment, and submit")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            Section {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($field, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { field = .password }
                SecureField("Password", text: $password)
                    .textContentType(creating ? .newPassword : .password)
                    .focused($field, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { Task { await submit() } }
            } footer: {
                if let error {
                    Text(error.localizedDescription).foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task { await submit() }
                } label: {
                    HStack {
                        Spacer()
                        if isWorking { ProgressView() } else { Text(creating ? "Create Account" : "Sign In").bold() }
                        Spacer()
                    }
                }
                .disabled(username.isEmpty || password.isEmpty || isWorking)

                Button(creating ? "I already have an account" : "Create an account") {
                    withAnimation { creating.toggle() }
                }
                .frame(maxWidth: .infinity)

                Button("Sign in on the web") { showingWebSignIn = true }
                    .frame(maxWidth: .infinity)
            } footer: {
                Text("Your password is sent only to news.ycombinator.com. The app keeps the session cookie in your Keychain, never the password.")
            }
        }
        .sheet(isPresented: $showingWebSignIn) {
            WebSignInView { cookie in
                session.adopt(cookie)
                Task { await session.refresh() }
                showingWebSignIn = false
                if isSheet { dismiss() }
            }
        }
    }

    private func submit() async {
        guard !username.isEmpty, !password.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            if creating {
                try await session.createAccount(username: username, password: password)
            } else {
                try await session.signIn(username: username, password: password)
            }
            password = ""
            error = nil
            if isSheet { dismiss() }
        } catch {
            self.error = error
            if let hn = error as? HNError, hn == .captchaRequired { showingWebSignIn = true }
        }
    }
}

struct SignInSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SignInView(isSheet: true)
                .navigationTitle("Sign In")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", systemImage: "xmark") { dismiss() }
                    }
                }
        }
    }
}

/// HN's own login page in a web view, for when it demands a captcha.
/// We watch the web view's cookies and hand back the `user` cookie once it appears.
struct WebSignInView: View {
    var onSignedIn: (HTTPCookie) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LoginWebView(onSignedIn: onSignedIn)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("news.ycombinator.com")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", systemImage: "xmark") { dismiss() }
                    }
                }
        }
    }
}

private struct LoginWebView: UIViewRepresentable {
    var onSignedIn: (HTTPCookie) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSignedIn: onSignedIn) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: HNClient.url("login?goto=news")))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onSignedIn: (HTTPCookie) -> Void
        private var finished = false

        init(onSignedIn: @escaping (HTTPCookie) -> Void) { self.onSignedIn = onSignedIn }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                guard !finished,
                      let cookie = cookies.first(where: { $0.name == HNClient.cookieName && $0.domain.contains("ycombinator.com") && !$0.value.isEmpty })
                else { return }
                finished = true
                onSignedIn(cookie)
            }
        }
    }
}
