import Foundation
import Observation
import SwiftUI

// MARK: - Settings

@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var openLinksInApp: Bool { didSet { defaults.set(openLinksInApp, forKey: "openLinksInApp") } }
    var readerMode: Bool { didSet { defaults.set(readerMode, forKey: "readerMode") } }
    var collapseOnTap: Bool { didSet { defaults.set(collapseOnTap, forKey: "collapseOnTap") } }
    var dimReadStories: Bool { didSet { defaults.set(dimReadStories, forKey: "dimReadStories") } }
    var showRank: Bool { didSet { defaults.set(showRank, forKey: "showRank") } }
    var defaultFeed: FeedKind { didSet { defaults.set(defaultFeed.rawValue, forKey: "defaultFeed") } }

    init() {
        defaults.register(defaults: [
            "openLinksInApp": true,
            "readerMode": false,
            "collapseOnTap": true,
            "dimReadStories": true,
            "showRank": true,
        ])
        openLinksInApp = defaults.bool(forKey: "openLinksInApp")
        readerMode = defaults.bool(forKey: "readerMode")
        collapseOnTap = defaults.bool(forKey: "collapseOnTap")
        dimReadStories = defaults.bool(forKey: "dimReadStories")
        showRank = defaults.bool(forKey: "showRank")
        defaultFeed = defaults.string(forKey: "defaultFeed").flatMap(FeedKind.init(rawValue:)) ?? .top
    }
}

// MARK: - Read history

/// Remembers which stories you've opened and how many comments they had,
/// so the feed can dim read stories and badge new comments.
@Observable
final class ReadStore {
    private(set) var seenCommentCounts: [Int: Int]
    private let key = "seenCommentCounts"
    private let limit = 4000

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Int: Int].self, from: data) {
            seenCommentCounts = decoded
        } else {
            seenCommentCounts = [:]
        }
    }

    func isRead(_ id: Int) -> Bool { seenCommentCounts[id] != nil }

    func markRead(_ story: Story) {
        markRead(id: story.id, commentCount: story.commentCount ?? 0)
    }

    func markRead(id: Int, commentCount: Int) {
        guard seenCommentCounts[id] != commentCount else { return }
        seenCommentCounts[id] = max(commentCount, seenCommentCounts[id] ?? 0)
        if seenCommentCounts.count > limit {
            // Item ids increase over time, so the smallest ids are the oldest stories.
            for id in seenCommentCounts.keys.sorted().prefix(seenCommentCounts.count - limit) {
                seenCommentCounts[id] = nil
            }
        }
        if let data = try? JSONEncoder().encode(seenCommentCounts) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - Toasts & sign-in prompts

@Observable
final class Notifier {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var message: String
        var systemImage: String
    }

    private(set) var toast: Toast?
    /// Set when an action needed an account; the root view presents the sign-in sheet.
    var signInRequested = false

    func show(_ message: String, systemImage: String = "checkmark.circle.fill") {
        let toast = Toast(message: message, systemImage: systemImage)
        withAnimation(.snappy) { self.toast = toast }
        AccessibilityNotification.Announcement(message).post()
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if self.toast?.id == toast.id {
                withAnimation(.snappy) { self.toast = nil }
            }
        }
    }

    func show(_ error: any Error) {
        if let hn = error as? HNError, hn == .notLoggedIn {
            signInRequested = true
            return
        }
        if error is CancellationError { return }
        show(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
    }
}

// MARK: - Actions

/// Runs account actions against HN, fetching fresh auth links when a list didn't include them.
enum ItemActionRunner {
    static func vote(_ target: VoteState, id: Int, actions: ItemActions) async throws -> ItemActions {
        var actions = actions
        if actions.voteAuth == nil {
            actions.merge(try await HNClient.shared.actions(for: id))
        }
        guard let auth = actions.voteAuth else { throw HNError.notLoggedIn }
        if target == .down && !actions.canDownvote {
            throw HNError.server("Downvoting unlocks at 501 karma, and only works on comments.")
        }
        let how = switch target {
        case .up: "up"
        case .down: "down"
        case .none: "un"
        }
        try await HNClient.shared.vote(id: id, how: how, auth: auth)
        actions.vote = target
        return actions
    }

    enum Toggle: String { case favorite = "fave", hide, flag }

    static func toggle(_ toggle: Toggle, id: Int, actions: ItemActions) async throws -> ItemActions {
        var actions = actions
        let current: Bool? = switch toggle {
        case .favorite: actions.favorited
        case .hide: actions.hidden
        case .flag: actions.flagged
        }
        var key = current == true ? "un" + toggle.rawValue : toggle.rawValue
        if actions.links[key] == nil {
            let fresh = try await HNClient.shared.actions(for: id)
            actions.merge(fresh)
            let refreshed: Bool? = switch toggle {
            case .favorite: fresh.favorited
            case .hide: fresh.hidden
            case .flag: fresh.flagged
            }
            key = refreshed == true ? "un" + toggle.rawValue : toggle.rawValue
        }
        guard let href = actions.links[key] else {
            throw HNClient.sessionCookie == nil ? HNError.notLoggedIn : HNError.actionUnavailable
        }
        try await HNClient.shared.follow(href)
        let newValue = !key.hasPrefix("un")
        switch toggle {
        case .favorite: actions.favorited = newValue
        case .hide: actions.hidden = newValue
        case .flag: actions.flagged = newValue
        }
        // The opposite link has its own token; fetch it fresh next time.
        actions.links[toggle.rawValue] = nil
        actions.links["un" + toggle.rawValue] = nil
        return actions
    }
}

extension Color {
    /// HN orange, tuned per appearance to meet 4.5:1 text contrast (see AccentColor in the asset catalog).
    static let hnOrange = Color("AccentColor")
}
