import SwiftUI

struct StoryRow: View {
    @Binding var story: Story
    var showRank = true
    var onHide: (() -> Void)?

    @Environment(\.openURL) private var openURL
    @Environment(ReadStore.self) private var readStore
    @Environment(AppSettings.self) private var settings
    @Environment(Notifier.self) private var notifier
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isRead: Bool { settings.dimReadStories && readStore.isRead(story.id) }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
        layout {
            Button {
                readStore.markRead(story)
                openURL(story.destinationURL)
            } label: {
                content
            }
            .buttonStyle(.plain)

            if !story.isJob {
                // A Button (not NavigationLink) so the List doesn't add a disclosure chevron;
                // the HN URL is routed to the thread by RoutedStack.
                Button {
                    readStore.markRead(story)
                    openURL(story.hnURL)
                } label: {
                    commentsBadge
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !story.isJob {
                Button { vote() } label: {
                    Label(story.actions.vote == .up ? "Unvote" : "Upvote",
                          systemImage: story.actions.vote == .up ? "arrow.uturn.down" : "arrow.up")
                }
                .tint(.hnOrange)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button { toggle(.hide) } label: { Label("Hide", systemImage: "eye.slash") }
                .tint(.gray)
            Button { toggle(.favorite) } label: {
                Label(story.actions.favorited == true ? "Unfavorite" : "Favorite",
                      systemImage: story.actions.favorited == true ? "star.slash" : "star")
            }
            .tint(.yellow)
        }
        .contextMenu {
            StoryMenu(story: $story, onHide: onHide)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Source line: rank · site · age
            HStack(spacing: 5) {
                if showRank && settings.showRank, let rank = story.rank {
                    Text("\(rank)")
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                Text(story.site ?? (story.isJob ? "Jobs" : "Discussion"))
                    .fontWeight(.medium)
                    .lineLimit(1)
                if let date = story.date {
                    Text("·").foregroundStyle(.tertiary)
                    Text(date.hnAge)
                }
                if story.actions.favorited == true {
                    Image(systemName: "star.fill")
                        .imageScale(.small)
                        .foregroundStyle(.yellow)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(story.title)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(isRead ? .secondary : .primary)
                .multilineTextAlignment(.leading)
                .lineLimit(4)

            if story.score != nil || story.author != nil {
                HStack(spacing: 4) {
                    if let score = story.score {
                        Image(systemName: story.actions.vote == .up ? "arrowshape.up.fill" : "arrowshape.up")
                            .imageScale(.small)
                        Text(score.compact)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    if let author = story.author {
                        Text(story.score == nil ? author : "· \(author)")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(story.actions.vote == .up ? AnyShapeStyle(Color.hnOrange) : AnyShapeStyle(.secondary))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    private var commentsBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "bubble.left")
                .imageScale(.small)
            Text((story.commentCount ?? 0).compact)
                .monospacedDigit()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.fill.tertiary, in: .capsule)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(.rect)
        .accessibilityLabel("\(story.commentCount ?? 0) comments")
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

    private func toggle(_ kind: ItemActionRunner.Toggle) {
        StoryMenu.toggle(kind, story: $story, notifier: notifier, onHide: onHide)
    }
}

/// Shared by the row's context menu and the thread header's "More" menu.
struct StoryMenu: View {
    @Binding var story: Story
    var onHide: (() -> Void)?

    @Environment(\.openURL) private var openURL
    @Environment(Notifier.self) private var notifier

    var body: some View {
        if let url = story.url {
            Button { openURL(url) } label: { Label("Open Link", systemImage: "safari") }
            Button { UIApplication.shared.open(url) } label: { Label("Open in Safari", systemImage: "arrow.up.forward.app") }
        }
        Button { openURL(story.hnURL) } label: { Label("View Comments", systemImage: "bubble.left.and.bubble.right") }
        Button { UIApplication.shared.open(story.hnURL) } label: { Label("Open on Hacker News", systemImage: "globe") }
        if let author = story.author {
            Button { openURL(HNClient.url("user?id=\(author.urlQueryEscaped)")) } label: {
                Label(author, systemImage: "person")
            }
        }
        Divider()
        ShareLink(item: story.url ?? story.hnURL) { Label("Share Link", systemImage: "square.and.arrow.up") }
        ShareLink(item: story.hnURL) { Label("Share Discussion", systemImage: "bubble.left.and.text.bubble.right") }
        Button { UIPasteboard.general.url = story.url ?? story.hnURL } label: { Label("Copy Link", systemImage: "doc.on.doc") }
        Divider()
        Button { run(.favorite) } label: {
            Label(story.actions.favorited == true ? "Unfavorite" : "Favorite",
                  systemImage: story.actions.favorited == true ? "star.slash" : "star")
        }
        Button { run(.hide) } label: {
            Label(story.actions.hidden == true ? "Unhide" : "Hide", systemImage: "eye.slash")
        }
        Button(role: .destructive) { run(.flag) } label: {
            Label(story.actions.flagged == true ? "Unflag" : "Flag", systemImage: "flag")
        }
    }

    private func run(_ kind: ItemActionRunner.Toggle) {
        Self.toggle(kind, story: $story, notifier: notifier, onHide: onHide)
    }

    static func toggle(_ kind: ItemActionRunner.Toggle, story: Binding<Story>, notifier: Notifier, onHide: (() -> Void)?) {
        Task {
            do {
                let actions = try await ItemActionRunner.toggle(kind, id: story.wrappedValue.id, actions: story.wrappedValue.actions)
                story.wrappedValue.actions = actions
                if kind == .hide, actions.hidden == true { withAnimation { onHide?() } }
                let (message, icon) = switch kind {
                case .favorite: (actions.favorited == true ? "Added to favorites" : "Removed from favorites", "star")
                case .hide: (actions.hidden == true ? "Hidden" : "Unhidden", "eye.slash")
                case .flag: (actions.flagged == true ? "Flagged" : "Unflagged", "flag")
                }
                notifier.show(message, systemImage: icon)
            } catch {
                notifier.show(error)
            }
        }
    }
}
