import SwiftUI

/// Callbacks a comment row needs from its thread. Lists outside a thread pass `nil` for most.
struct CommentRowActions {
    var toggleCollapse: (() -> Void)?
    var collapseThread: (() -> Void)?
    var reply: (() -> Void)?
    var edit: (() -> Void)?
    var delete: (() -> Void)?
}

struct CommentRow: View {
    @Binding var comment: Comment
    var opAuthor: String?
    var isCollapsed = false
    var hiddenReplies = 0
    /// Show "on: <story>" for comments listed outside their thread.
    var showsContext = false
    /// The comment this one replies to, shown above it in lists.
    var replyingTo: ParentPreview?
    var actions = CommentRowActions()

    @Environment(\.openURL) private var openURL
    @Environment(\.commentTapOpensThread) private var tapOpensThread
    @Environment(SessionStore.self) private var session
    @Environment(AppSettings.self) private var settings
    @Environment(Notifier.self) private var notifier
    @State private var showingSelectableText = false
    @State private var confirmingDelete = false
    @State private var composeTarget: ComposeTarget?

    // Threads pass their own actions; in comment lists (showsContext) the row handles them itself.
    private var replyAction: (() -> Void)? {
        guard !comment.isDeleted, comment.id > 0 else { return nil }
        if let reply = actions.reply { return reply }
        guard showsContext else { return nil }
        return {
            guard session.isSignedIn else { notifier.signInRequested = true; return }
            composeTarget = ComposeTarget(mode: .reply(parentID: comment.id), context: comment.text, contextAuthor: comment.author)
        }
    }

    private var editAction: (() -> Void)? {
        if let edit = actions.edit { return edit }
        guard showsContext else { return nil }
        return { composeTarget = ComposeTarget(mode: .edit(commentID: comment.id)) }
    }

    private var deleteAction: (() -> Void)? {
        if let delete = actions.delete { return delete }
        guard showsContext else { return nil }
        return {
            Task {
                do {
                    try await HNClient.shared.delete(id: comment.id)
                    comment.isDeleted = true
                    comment.text = AttributedString("[deleted]")
                    notifier.show("Comment deleted", systemImage: "trash")
                } catch {
                    notifier.show(error)
                }
            }
        }
    }

    private static let depthColors: [Color] = [.hnOrange, .blue, .green, .purple, .pink, .teal, .yellow, .indigo]
    /// Beyond this many levels the rails stop indenting, so deep threads keep a readable width.
    private static let maxRails = 8

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // One thin rail per nesting level; the innermost is tinted.
            ForEach(0..<min(comment.depth, Self.maxRails), id: \.self) { level in
                let isInnermost = level == min(comment.depth, Self.maxRails) - 1
                Rectangle()
                    .fill(isInnermost
                          ? AnyShapeStyle(Self.depthColors[level % Self.depthColors.count].opacity(0.75))
                          : AnyShapeStyle(.separator))
                    .frame(width: isInnermost ? 2 : 1)
                    .padding(.trailing, isInnermost ? 10 : 11)
            }
            VStack(alignment: .leading, spacing: 5) {
                if showsContext {
                    listContext
                }
                header
                if !isCollapsed {
                    Text(comment.text)
                        .font(.subheadline)
                        .lineSpacing(1.5)
                        .foregroundStyle(comment.isDeleted || comment.isDead ? .secondary : .primary)
                        .opacity(1 - comment.fade)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        // Remove instantly: a fading view stays in the layout and makes
                        // the List re-center the row while it resizes (the header jumps).
                        .transition(.identity)
                }
            }
            .padding(.vertical, 9)
        }
        // While the List animates a row's height (collapse/expand), keep the content exactly
        // the row's current height, pinned to the top: with both min and max set, the frame
        // adopts the proposed height, so content is never re-centered in a shorter/taller cell.
        // Clipping turns expansion into a top-down reveal instead of text spilling over the next row.
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .contentShape(.rect)
        .onTapGesture {
            if tapOpensThread {
                openURL(comment.contextURL)
            } else if settings.collapseOnTap, let toggle = actions.toggleCollapse {
                withAnimation(.snappy(duration: 0.25)) { toggle() }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !comment.isDeleted {
                Button { vote(comment.actions.vote == .up ? .none : .up) } label: {
                    Label(comment.actions.vote == .up ? "Unvote" : "Upvote",
                          systemImage: comment.actions.vote == .up ? "arrow.uturn.down" : "arrow.up")
                }
                .tint(.hnOrange)
                if comment.actions.canDownvote || comment.actions.vote == .down {
                    Button { vote(comment.actions.vote == .down ? .none : .down) } label: {
                        Label(comment.actions.vote == .down ? "Undown" : "Downvote", systemImage: "arrow.down")
                    }
                    .tint(.indigo)
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if let reply = replyAction {
                Button(action: reply) { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                    .tint(.blue)
            }
            if let collapse = actions.collapseThread {
                Button { withAnimation { collapse() } } label: { Label("Collapse Thread", systemImage: "arrow.up.to.line") }
                    .tint(.gray)
            }
        }
        .contextMenu { menu }
        .sheet(item: $composeTarget) { target in
            ComposeView(target: target) { text in
                switch target.mode {
                case .reply:
                    notifier.show("Reply posted", systemImage: "arrowshape.turn.up.left.fill")
                case .edit:
                    comment.text = AttributedString(text)
                    comment.plainText = text
                    notifier.show("Comment updated", systemImage: "pencil")
                }
            }
        }
        .sheet(isPresented: $showingSelectableText) {
            SelectableTextView(text: comment.text, author: comment.author)
        }
        .confirmationDialog("Delete this comment?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteAction?() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Upvote") { vote(.up) }
        .accessibilityAction(named: "Reply") { replyAction?() }
        .accessibilityAction(named: isCollapsed ? "Expand" : "Collapse") { actions.toggleCollapse?() }
    }

    /// For comments listed outside their thread: the story, then what this comment replied to.
    @ViewBuilder
    private var listContext: some View {
        if let title = comment.storyTitle, comment.depth == 0 {
            HStack(spacing: 5) {
                Image(systemName: "doc.text")
                Text(title).lineLimit(1)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
        if let parent = replyingTo, comment.depth == 0 {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(.separator)
                    .frame(width: 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(parent.author ?? "deleted")
                        .font(.caption.weight(.semibold))
                    Text(parent.text)
                        .font(.caption)
                        .lineLimit(3)
                }
                .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 2)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let author = comment.author {
                let isOP = author == opAuthor
                let isMe = author == session.username
                Text(author)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(isOP ? Color.hnOrange : isMe ? Color.blue : Color.primary)
                    .lineLimit(1)
                if isOP || isMe {
                    Text(isOP ? "OP" : "You")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(isOP ? Color.hnOrange : Color.blue)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background((isOP ? Color.hnOrange : Color.blue).opacity(0.14), in: .capsule)
                }
            } else {
                Text("deleted").font(.footnote).foregroundStyle(.tertiary)
            }
            if let date = comment.date {
                Text(date.hnAge)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            if comment.isDead {
                Text("dead").font(.footnote).foregroundStyle(.red)
            }
            Spacer(minLength: 4)
            Group {
                if comment.actions.favorited == true {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                }
                switch comment.actions.vote {
                case .up: Image(systemName: "arrowshape.up.fill").foregroundStyle(Color.hnOrange)
                case .down: Image(systemName: "arrowshape.down.fill").foregroundStyle(.indigo)
                case .none: EmptyView()
                }
            }
            .font(.caption)
            // The reply button and the collapsed-count chip share one slot that is always laid
            // out, so collapsing/expanding never changes the header's size (no username wobble).
            ZStack(alignment: .trailing) {
                if let reply = replyAction {
                    Button(action: reply) {
                        Image(systemName: "arrowshape.turn.up.left")
                            .font(.footnote.weight(.medium))
                            // Explicit Color: inside a button, `.secondary` would be the tint (orange) at reduced opacity.
                            .foregroundStyle(Color.secondary)
                            .frame(width: 44)
                            // ~40pt-tall tap area without adding layout height.
                            .padding(.vertical, 10)
                            .contentShape(.rect)
                            .padding(.vertical, -10)
                    }
                    .buttonStyle(.borderless)
                    // Nudge only the arrow toward the edge (offset doesn't affect layout),
                    // so the chip in the same slot stays fully inside the row.
                    .offset(x: 12)
                    .opacity(isCollapsed ? 0 : 1)
                    .allowsHitTesting(!isCollapsed)
                    .accessibilityHidden(isCollapsed)
                    .accessibilityLabel("Reply")
                }
                HStack(spacing: 3) {
                    if hiddenReplies > 0 { Text("\(hiddenReplies)") }
                    Image(systemName: "chevron.down")
                }
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.fill.tertiary, in: .capsule)
                .opacity(isCollapsed ? 1 : 0)
                .accessibilityHidden(!isCollapsed)
            }
            // Whatever is inside, contribute no height beyond the text line.
            .frame(height: 1)
        }
    }

    @ViewBuilder
    private var menu: some View {
        if !comment.isDeleted {
            Section {
                if comment.actions.vote == .none {
                    Button { vote(.up) } label: { Label("Upvote", systemImage: "arrow.up") }
                    if comment.actions.canDownvote {
                        Button { vote(.down) } label: { Label("Downvote", systemImage: "arrow.down") }
                    }
                } else {
                    Button { vote(.none) } label: {
                        Label(comment.actions.vote == .up ? "Unvote" : "Undown", systemImage: "arrow.uturn.backward")
                    }
                }
                if let reply = replyAction {
                    Button(action: reply) { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                }
            }
        }
        if comment.actions.canEdit || comment.actions.canDelete {
            Section {
                if comment.actions.canEdit, let edit = editAction {
                    Button(action: edit) { Label("Edit", systemImage: "pencil") }
                }
                if comment.actions.canDelete, deleteAction != nil {
                    Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        Section {
            if let toggle = actions.toggleCollapse {
                Button { withAnimation { toggle() } } label: {
                    Label(isCollapsed ? "Expand" : "Collapse", systemImage: isCollapsed ? "chevron.down" : "chevron.up")
                }
            }
            if let collapseThread = actions.collapseThread, comment.depth > 0 {
                Button { withAnimation { collapseThread() } } label: { Label("Collapse Thread", systemImage: "arrow.up.to.line") }
            }
            if let author = comment.author {
                Button { openURL(HNClient.url("user?id=\(author.urlQueryEscaped)")) } label: { Label(author, systemImage: "person") }
            }
            if comment.storyID != nil {
                Button { openURL(comment.contextURL) } label: { Label("Show in Thread", systemImage: "text.bubble") }
            }
            Button { openURL(comment.hnURL) } label: { Label("Open Permalink", systemImage: "link") }
        }
        Section {
            Button { UIPasteboard.general.string = comment.plainText } label: { Label("Copy Text", systemImage: "doc.on.doc") }
            Button { showingSelectableText = true } label: { Label("Select Text", systemImage: "selection.pin.in.out") }
            ShareLink(item: comment.hnURL) { Label("Share", systemImage: "square.and.arrow.up") }
        }
        if !comment.isDeleted {
            Section {
                Button { toggle(.favorite) } label: {
                    Label(comment.actions.favorited == true ? "Unfavorite" : "Favorite",
                          systemImage: comment.actions.favorited == true ? "star.slash" : "star")
                }
                Button(role: .destructive) { toggle(.flag) } label: {
                    Label(comment.actions.flagged == true ? "Unflag" : "Flag", systemImage: "flag")
                }
            }
        }
    }

    private func vote(_ target: VoteState) {
        guard comment.id > 0 else { return }
        let previous = comment.actions
        withAnimation { comment.actions.vote = target }
        Task {
            do {
                comment.actions = try await ItemActionRunner.vote(target, id: comment.id, actions: previous)
            } catch {
                comment.actions = previous
                notifier.show(error)
            }
        }
    }

    private func toggle(_ kind: ItemActionRunner.Toggle) {
        guard comment.id > 0 else { return }
        Task {
            do {
                comment.actions = try await ItemActionRunner.toggle(kind, id: comment.id, actions: comment.actions)
                switch kind {
                case .favorite: notifier.show(comment.actions.favorited == true ? "Added to favorites" : "Removed from favorites", systemImage: "star")
                case .flag: notifier.show(comment.actions.flagged == true ? "Flagged" : "Unflagged", systemImage: "flag")
                case .hide: break
                }
            } catch {
                notifier.show(error)
            }
        }
    }
}

struct SelectableTextView: View {
    let text: AttributedString
    let author: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(author ?? "Comment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
