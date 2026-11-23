import Foundation

// MARK: - Feeds

/// The front-page feeds, read from the official Firebase API.
nonisolated enum FeedKind: String, CaseIterable, Identifiable, Hashable, Sendable, Codable {
    case top, new, best, ask, show, jobs

    var id: String { rawValue }

    /// `/v0/<name>.json` on hacker-news.firebaseio.com
    var apiName: String {
        switch self {
        case .top: "topstories"
        case .new: "newstories"
        case .best: "beststories"
        case .ask: "askstories"
        case .show: "showstories"
        case .jobs: "jobstories"
        }
    }

    /// The matching page on the website, used only to overlay the signed-in user's votes.
    var webPath: String {
        switch self {
        case .top: "news"
        case .new: "newest"
        case .best: "best"
        case .ask: "ask"
        case .show: "show"
        case .jobs: "jobs"
        }
    }

    /// Whether the website paginates this feed with `?p=N` (the others use opaque cursors).
    var webSupportsPageNumbers: Bool { self != .new && self != .jobs }

    var title: String {
        switch self {
        case .top: "Top"
        case .new: "New"
        case .best: "Best"
        case .ask: "Ask HN"
        case .show: "Show HN"
        case .jobs: "Jobs"
        }
    }

    var systemImage: String {
        switch self {
        case .top: "flame"
        case .new: "clock"
        case .best: "trophy"
        case .ask: "questionmark.bubble"
        case .show: "eye"
        case .jobs: "briefcase"
        }
    }
}

/// Anything that renders as a paginated list of stories.
nonisolated enum StoryListSource: Hashable, Sendable {
    /// Official API.
    case feed(FeedKind)
    /// Algolia (`author_<name>`).
    case submitted(user: String)
    /// Website only: these lists are tied to the account and absent from the API.
    case favorites(user: String)
    case upvoted(user: String)
    case hidden(user: String)

    var webPath: String? {
        switch self {
        case .feed, .submitted: nil
        case .favorites(let user): "favorites?id=\(user.urlQueryEscaped)"
        case .upvoted(let user): "upvoted?id=\(user.urlQueryEscaped)"
        case .hidden(let user): "hidden?id=\(user.urlQueryEscaped)"
        }
    }

    var title: String {
        switch self {
        case .feed(let kind): kind.title
        case .submitted: "Submissions"
        case .favorites: "Favorite Stories"
        case .upvoted: "Upvoted Stories"
        case .hidden: "Hidden"
        }
    }
}

/// Anything that renders as a paginated list of comments.
nonisolated enum CommentListSource: Hashable, Sendable {
    /// Algolia (`author_<name>`).
    case byUser(String)
    /// Website only.
    case threads(user: String)
    case favorites(user: String)
    case upvoted(user: String)

    var webPath: String? {
        switch self {
        case .byUser: nil
        case .threads(let user): "threads?id=\(user.urlQueryEscaped)"
        case .favorites(let user): "favorites?id=\(user.urlQueryEscaped)&comments=t"
        case .upvoted(let user): "upvoted?id=\(user.urlQueryEscaped)&comments=t"
        }
    }

    var title: String {
        switch self {
        case .byUser: "Comments"
        case .threads: "Threads"
        case .favorites: "Favorite Comments"
        case .upvoted: "Upvoted Comments"
        }
    }
}

/// Where the next page of a list comes from.
nonisolated enum PageCursor: Hashable, Sendable {
    /// The id list from the official API, and how far into it we've loaded.
    case ids([Int], offset: Int)
    /// Algolia page number.
    case page(Int)
    /// The website's "More" link.
    case url(URL)
}

// MARK: - Item actions

nonisolated enum VoteState: Hashable, Sendable {
    case none, up, down
}

/// What the signed-in user can do with an item, scraped from the links HN renders for it.
/// Each link carries an `auth` token tied to the account, which is why actions need the HTML.
nonisolated struct ItemActions: Hashable, Sendable {
    var voteAuth: String?
    var vote: VoteState = .none
    var canDownvote = false

    var favorited: Bool?
    var hidden: Bool?
    var flagged: Bool?

    /// Raw hrefs keyed by action name ("fave", "unfave", "hide", "unhide", "flag", "unflag", "edit", "delete", "reply").
    var links: [String: String] = [:]

    var canVote: Bool { voteAuth != nil }
    var canEdit: Bool { links["edit"] != nil }
    var canDelete: Bool { links["delete"] != nil }

    mutating func merge(_ other: ItemActions) {
        if let auth = other.voteAuth { voteAuth = auth }
        if other.vote != .none { vote = other.vote }
        canDownvote = canDownvote || other.canDownvote
        favorited = other.favorited ?? favorited
        hidden = other.hidden ?? hidden
        flagged = other.flagged ?? flagged
        links.merge(other.links) { _, new in new }
    }
}

// MARK: - Content

nonisolated struct Story: Identifiable, Hashable, Sendable {
    let id: Int
    var rank: Int?
    var title: String
    var url: URL?
    var site: String?
    var score: Int?
    var author: String?
    var date: Date?
    var commentCount: Int?
    var text: AttributedString?
    var isDead = false
    var isFlagged = false
    var pollOptions: [PollOption] = []
    var actions = ItemActions()

    var isJob: Bool { author == nil && score == nil }
    var hnURL: URL { URL(string: "https://news.ycombinator.com/item?id=\(id)")! }
    /// Where tapping the title goes: the article, or the discussion for text posts.
    var destinationURL: URL { url ?? hnURL }
}

nonisolated struct PollOption: Identifiable, Hashable, Sendable {
    let id: Int
    var text: String
    var score: Int
    var actions = ItemActions()
}

nonisolated struct Comment: Identifiable, Hashable, Sendable {
    let id: Int
    var depth: Int
    var parentID: Int?
    var author: String?
    var date: Date?
    var text: AttributedString
    var plainText: String
    /// 0 = normal, up to ~0.75 for heavily downvoted comments that HN renders in grey.
    var fade: Double = 0
    var isDeleted = false
    var isDead = false
    var storyID: Int?
    var storyTitle: String?
    var actions = ItemActions()

    var hnURL: URL { URL(string: "https://news.ycombinator.com/item?id=\(id)")! }

    /// The full story thread scrolled to this comment (HN's "context" link), or the permalink
    /// when the story isn't known.
    var contextURL: URL {
        guard let storyID, storyID != id else { return hnURL }
        return URL(string: "https://news.ycombinator.com/item?id=\(storyID)#\(id)")!
    }
}

/// A short look at the comment someone replied to, shown above their reply in comment lists.
nonisolated struct ParentPreview: Hashable, Sendable {
    var author: String?
    var text: String
}

nonisolated struct UserProfile: Hashable, Sendable {
    let id: String
    var created: Date
    var karma: Int
    var about: AttributedString?
}

// MARK: - Pages

nonisolated struct StoryPage: Sendable {
    var stories: [Story]
    var next: PageCursor?
}

nonisolated struct CommentPage: Sendable {
    var comments: [Comment]
    var next: PageCursor?
}

/// A hidden-field form scraped from HN, e.g. the comment box with its `hmac`.
nonisolated struct HNForm: Hashable, Sendable {
    var action: String
    var fields: [String: String]
    var textareaValue: String?
}

nonisolated struct ThreadPage: Sendable {
    var story: Story?
    /// Set when the thread root is a comment (a permalink) instead of a story.
    var rootComment: Comment?
    var comments: [Comment]
    var replyForm: HNForm?
    var parentID: Int?
}

// MARK: - Helpers

nonisolated extension String {
    var urlQueryEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.~"))) ?? self
    }
}
