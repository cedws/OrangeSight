import SwiftUI

struct ComposeTarget: Identifiable {
    enum Mode {
        case reply(parentID: Int)
        case edit(commentID: Int)
    }
    let id = UUID()
    var mode: Mode
    /// What's being replied to, shown above the editor.
    var context: AttributedString?
    var contextAuthor: String?
}

struct ThreadView: View {
    @State private var model: ThreadModel
    @State private var composeTarget: ComposeTarget?
    @State private var visibleTopLevel: Set<Int> = []
    @State private var highlighted: Int?
    private let focus: Int?

    @Environment(SessionStore.self) private var session
    @Environment(ReadStore.self) private var readStore
    @Environment(Notifier.self) private var notifier
    @Environment(\.openURL) private var openURL

    init(id: Int, focus: Int? = nil) {
        _model = State(initialValue: ThreadModel(id: id))
        self.focus = focus
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                header
                    .listRowSeparator(.hidden)

                let visible = model.visible
                ForEach(visible) { item in
                    let comment = model.comments[item.index]
                    CommentRow(
                        comment: $model.comments[item.index],
                        opAuthor: model.opAuthor,
                        isCollapsed: model.collapsed.contains(comment.id),
                        hiddenReplies: model.replyCounts[comment.id] ?? 0,
                        actions: rowActions(for: comment)
                    )
                    .id(comment.id)
                    .listRowBackground(highlighted == comment.id ? Color.hnOrange.opacity(0.12) : Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    // Only separate top-level threads; replies flow under their parent.
                    .listRowSeparator(.hidden)
                    .overlay(alignment: .top) {
                        if comment.depth == 0 && item.index > 0 { Divider() }
                    }
                    .onAppear { if comment.depth == 0 { visibleTopLevel.insert(item.index) } }
                    .onDisappear { visibleTopLevel.remove(item.index) }
                }

                if model.hasLoaded && model.comments.isEmpty && model.error == nil {
                    Text("No comments yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .refreshable { await model.load() }
            // Let collapsed comments be shorter than the default 44pt row.
            .environment(\.defaultMinListRowHeight, 0)
            .overlay {
                if !model.hasLoaded {
                    ProgressView()
                } else if let error = model.error, model.story == nil && model.rootComment == nil {
                    ErrorView(error: error) { Task { await model.load() } }
                }
            }
            .onChange(of: model.hasLoaded) { _, loaded in
                guard loaded, let focus, model.comments.contains(where: { $0.id == focus }) else { return }
                Task {
                    // Let the List lay out its rows before scrolling.
                    try? await Task.sleep(for: .milliseconds(300))
                    withAnimation { proxy.scrollTo(focus, anchor: .center) }
                    highlighted = focus
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation(.easeOut(duration: 0.8)) { highlighted = nil }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if model.comments.count > 3 {
                    Button {
                        let current = visibleTopLevel.min() ?? -1
                        if let next = model.nextTopLevel(after: current) {
                            withAnimation { proxy.scrollTo(next, anchor: .top) }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .padding()
                    .accessibilityLabel("Next top-level comment")
                }
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task {
            guard !model.hasLoaded else { return }
            await model.load()
            if let story = model.story { readStore.markRead(story) }
        }
        .sheet(item: $composeTarget) { target in
            ComposeView(target: target) { text in
                handleComposed(target: target, text: text)
            }
        }
    }

    private var navigationTitle: String {
        if let count = model.story?.commentCount { return "\(count) Comments" }
        if model.rootComment != nil { return "Comment" }
        return ""
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        if model.story != nil {
            StoryHeader(story: Binding(get: { model.story! }, set: { model.story = $0 })) {
                compose(replyTo: model.id, context: nil, author: nil)
            }
        } else if let root = model.rootComment {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if let parent = model.parentID {
                        Button { openURL(HNClient.url("item?id=\(parent)")) } label: {
                            Label("Parent", systemImage: "arrow.up.left")
                        }
                    }
                    if let storyID = root.storyID, storyID != model.parentID {
                        Button { openURL(HNClient.url("item?id=\(storyID)")) } label: {
                            Label("Story", systemImage: "doc.text")
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                CommentRow(
                    comment: Binding(get: { model.rootComment! }, set: { model.rootComment = $0 }),
                    opAuthor: root.author,
                    actions: CommentRowActions(
                        reply: { compose(replyTo: root.id, context: root.text, author: root.author) },
                        edit: { composeEdit(root) }
                    )
                )
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if model.comments.contains(where: { $0.depth == 0 }) {
                let anyCollapsed = !model.collapsed.isEmpty
                Button {
                    withAnimation(.snappy) {
                        model.collapsed = anyCollapsed ? [] : Set(model.comments.filter { $0.depth == 0 }.map(\.id))
                    }
                } label: {
                    Label(anyCollapsed ? "Expand All" : "Collapse All",
                          systemImage: anyCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                }
                // Monochrome toolbar; the accent is reserved for state in the content.
                .tint(.primary)
            }
        }
    }

    // MARK: Actions

    private func rowActions(for comment: Comment) -> CommentRowActions {
        let id = comment.id
        return CommentRowActions(
            toggleCollapse: { model.toggleCollapse(id) },
            collapseThread: { model.collapseThread(containing: id) },
            reply: { compose(replyTo: id, context: comment.text, author: comment.author) },
            edit: { composeEdit(comment) },
            delete: { delete(id) }
        )
    }

    private func compose(replyTo id: Int, context: AttributedString?, author: String?) {
        guard session.isSignedIn else {
            notifier.signInRequested = true
            return
        }
        composeTarget = ComposeTarget(mode: .reply(parentID: id), context: context, contextAuthor: author)
    }

    private func composeEdit(_ comment: Comment) {
        composeTarget = ComposeTarget(mode: .edit(commentID: comment.id))
    }

    private func handleComposed(target: ComposeTarget, text: String) {
        switch target.mode {
        case .reply(let parentID):
            withAnimation { model.insertReply(text, parentID: parentID, author: session.username ?? "you") }
            notifier.show("Reply posted", systemImage: "arrowshape.turn.up.left.fill")
        case .edit(let commentID):
            model.updateText(of: commentID, to: text)
            notifier.show("Comment updated", systemImage: "pencil")
        }
        model.reloadSoon()
    }

    private func delete(_ id: Int) {
        Task {
            do {
                try await HNClient.shared.delete(id: id)
                withAnimation { model.markDeleted(id) }
                notifier.show("Comment deleted", systemImage: "trash")
            } catch {
                notifier.show(error)
            }
        }
    }
}

// MARK: - Story header

struct StoryHeader: View {
    @Binding var story: Story
    var reply: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(Notifier.self) private var notifier

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                if let site = story.site {
                    Text(site.uppercased())
                        .font(.caption.weight(.semibold))
                        .tracking(0.6)
                        .foregroundStyle(Color.hnOrange)
                } else if story.isJob {
                    Text("JOBS").font(.caption.weight(.semibold)).tracking(0.6).foregroundStyle(Color.hnOrange)
                }

                Text(story.title)
                    .font(.title2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)

                Text(byline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .tint(.primary)
            }

            if let url = story.url {
                Button { openURL(url) } label: {
                    LinkCard(url: url, site: story.site)
                }
                .buttonStyle(.plain)
            }

            if let text = story.text {
                Text(text)
                    .font(.callout)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !story.pollOptions.isEmpty {
                PollView(options: $story.pollOptions)
            }

            actionBar
        }
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    /// "426 points · SockThief · 6 hours ago", with the author linking to their profile.
    private var byline: AttributedString {
        var parts: [AttributedString] = []
        if let score = story.score {
            parts.append(AttributedString("\(score.formatted()) points"))
        }
        if let author = story.author {
            var name = AttributedString(author)
            name.link = HNClient.url("user?id=\(author.urlQueryEscaped)")
            name.inlinePresentationIntent = .stronglyEmphasized
            parts.append(name)
        }
        if let date = story.date {
            parts.append(AttributedString(date.formatted(.relative(presentation: .named))))
        }
        return parts.enumerated().reduce(into: AttributedString()) { result, item in
            if item.offset > 0 { result += AttributedString("  ·  ") }
            result += item.element
        }
    }

    private var actionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                if !story.isJob {
                    barButton(story.actions.vote == .up ? "Unvote" : "Upvote",
                              systemImage: story.actions.vote == .up ? "arrowshape.up.fill" : "arrowshape.up",
                              active: story.actions.vote == .up, action: vote)
                    barButton("Reply", systemImage: "arrowshape.turn.up.left", action: reply)
                }
                barButton(story.actions.favorited == true ? "Unfavorite" : "Favorite",
                          systemImage: story.actions.favorited == true ? "star.fill" : "star",
                          active: story.actions.favorited == true) {
                    StoryMenu.toggle(.favorite, story: $story, notifier: notifier, onHide: nil)
                }
                ShareLink(item: story.url ?? story.hnURL) {
                    barIcon("square.and.arrow.up", active: false)
                }
                .accessibilityLabel("Share")
                Menu {
                    StoryMenu(story: $story)
                } label: {
                    barIcon("ellipsis", active: false)
                }
                .accessibilityLabel("More")
            }
            .buttonStyle(.borderless)
            Divider()
        }
    }

    private func barButton(_ title: String, systemImage: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            barIcon(systemImage, active: active)
        }
        .accessibilityLabel(title)
    }

    private func barIcon(_ systemImage: String, active: Bool) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(active ? Color.hnOrange : Color.secondary)
            .symbolEffect(.bounce, value: active)
            .frame(maxWidth: .infinity, minHeight: 46)
            .contentShape(.rect)
    }

    private func vote() {
        let target: VoteState = story.actions.vote == .up ? .none : .up
        let previous = story
        withAnimation {
            story.actions.vote = target
            story.score = story.score.map { $0 + (target == .up ? 1 : -1) }
        }
        Task {
            do {
                story.actions = try await ItemActionRunner.vote(target, id: story.id, actions: previous.actions)
            } catch {
                story = previous
                notifier.show(error)
            }
        }
    }
}

/// A tappable preview of the story's link.
struct LinkCard: View {
    let url: URL
    let site: String?

    private var displayPath: String? {
        var path = url.path()
        if let query = url.query() { path += "?" + query }
        return path.isEmpty || path == "/" ? nil : path
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(String((site ?? url.host() ?? "?").prefix(1)).uppercased())
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.hnOrange.gradient, in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(site ?? url.host() ?? "Link")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let path = displayPath {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(.fill.quinary, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
        .contentShape(.rect)
    }
}

struct PollView: View {
    @Binding var options: [PollOption]
    @Environment(Notifier.self) private var notifier

    private var total: Int { max(1, options.reduce(0) { $0 + $1.score }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach($options) { $option in
                HStack(spacing: 10) {
                    Button {
                        vote(&option)
                    } label: {
                        Image(systemName: option.actions.vote == .up ? "arrow.up.circle.fill" : "arrow.up.circle")
                            .font(.title3)
                            .foregroundStyle(option.actions.vote == .up ? Color.hnOrange : .secondary)
                    }
                    .buttonStyle(.borderless)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(option.text).font(.subheadline)
                            Spacer()
                            Text("\(option.score)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        ProgressView(value: Double(option.score), total: Double(total))
                            .tint(.hnOrange)
                    }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
    }

    private func vote(_ option: inout PollOption) {
        let target: VoteState = option.actions.vote == .up ? .none : .up
        let id = option.id
        let previous = option.actions
        option.actions.vote = target
        option.score += target == .up ? 1 : -1
        Task {
            do {
                let updated = try await ItemActionRunner.vote(target, id: id, actions: previous)
                if let i = options.firstIndex(where: { $0.id == id }) { options[i].actions = updated }
            } catch {
                if let i = options.firstIndex(where: { $0.id == id }) {
                    options[i].actions = previous
                    options[i].score += target == .up ? -1 : 1
                }
                notifier.show(error)
            }
        }
    }
}
