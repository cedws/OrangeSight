import Foundation

nonisolated enum HNError: LocalizedError, Equatable {
    case http(Int)
    case rateLimited
    case notLoggedIn
    case badLogin
    case captchaRequired
    case actionUnavailable
    case server(String)
    case notFound

    var errorDescription: String? {
        switch self {
        case .http(let code): "Hacker News returned an error (\(code))."
        case .rateLimited: "Hacker News is rate limiting requests. Wait a moment and try again."
        case .notLoggedIn: "You need to sign in to do that."
        case .badLogin: "Incorrect username or password."
        case .captchaRequired: "Hacker News wants a captcha for this sign-in. Use “Sign in on the web” instead."
        case .actionUnavailable: "That action isn't available for this item."
        case .server(let message): message
        case .notFound: "Not found."
        }
    }
}

/// Talks to news.ycombinator.com (HTML, for everything tied to the account),
/// the official Firebase API (profiles), and Algolia (search).
nonisolated final class HNClient: Sendable {
    static let shared = HNClient()
    static let base = URL(string: "https://news.ycombinator.com/")!
    static let cookieName = "user"

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 25
        // Nothing these servers send is cacheable (no-cache / private, no validators), so skip
        // the URL cache entirely instead of writing every response to disk for nothing.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        // Compression: URLSession already sends `Accept-Encoding` (gzip, deflate, br) and decodes
        // transparently; setting the header by hand would turn that decoding off. HN only offers
        // gzip; Firebase and Algolia don't compress at all.
        // Connections: one shared session, so keep-alive (HTTP/1.1: HN, Firebase) and multiplexing
        // (HTTP/2 or 3: Algolia) are reused across every request in the app.
        session = URLSession(configuration: config)
    }

    static func url(_ path: String) -> URL {
        URL(string: path, relativeTo: base)!.absoluteURL
    }

    // MARK: Transport

    private func fetchHTML(_ url: URL) async throws -> (String, URL) {
        var request = URLRequest(url: url)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        return try await send(request)
    }

    private func post(_ path: String, fields: [String: String]) async throws -> (String, URL) {
        var request = URLRequest(url: Self.url(path))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = fields
            .map { "\($0.key.formEncoded)=\($0.value.formEncoded)" }
            .joined(separator: "&")
            .data(using: .utf8)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> (String, URL) {
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let body = String(decoding: data, as: UTF8.self)
        switch http?.statusCode ?? 200 {
        case 200..<400: break
        case 429, 503: throw HNError.rateLimited
        case 404: throw HNError.notFound
        case let code: throw HNError.http(code)
        }
        if body.count < 400, body.contains("not able to serve your requests this quickly") {
            throw HNError.rateLimited
        }
        return (body, response.url ?? request.url!)
    }

    // MARK: Reading — official API

    private static let api = URL(string: "https://hacker-news.firebaseio.com/v0/")!
    static let pageSize = 30

    nonisolated struct APIItem: Decodable, Sendable {
        let id: Int
        let type: String?
        let by: String?
        let time: TimeInterval?
        let text: String?
        let url: String?
        let title: String?
        let score: Int?
        let descendants: Int?
        let kids: [Int]?
        let parent: Int?
        let parts: [Int]?
        let dead: Bool?
        let deleted: Bool?

        var story: Story {
            let link = url.flatMap { $0.isEmpty ? nil : URL(string: $0) }
            return Story(
                id: id,
                title: HTML.decodeEntities(title ?? ""),
                url: link,
                site: link.flatMap(HNClient.displaySite),
                score: type == "job" ? nil : score,
                author: type == "job" ? nil : by,
                date: time.map { Date(timeIntervalSince1970: $0) },
                commentCount: type == "job" ? nil : (descendants ?? 0),
                text: text.map { HTML.attributed($0) },
                isDead: dead ?? false
            )
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        var request = URLRequest(url: url)
        // Algolia advertises HTTP/3; start on it instead of discovering it after an HTTP/2 round trip.
        if url.host() == "hn.algolia.com" { request.assumesHTTP3Capable = true }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw http.statusCode == 429 ? HNError.rateLimited : HNError.http(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func item(_ id: Int) async throws -> APIItem? {
        try await decode(APIItem?.self, from: Self.api.appending(path: "item/\(id).json"))
    }

    /// Fetches items concurrently, keeping the order of `ids`.
    private func items(_ ids: [Int]) async throws -> [APIItem] {
        try await withThrowingTaskGroup(of: (Int, APIItem?).self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask { (index, try await self.item(id)) }
            }
            var found: [(Int, APIItem)] = []
            for try await (index, item) in group {
                if let item { found.append((index, item)) }
            }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    static func displaySite(_ url: URL) -> String? {
        guard var host = url.host() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if host == "github.com" || host == "gitlab.com" || host == "twitter.com" || host == "x.com",
           let owner = url.pathComponents.dropFirst().first {
            return "\(host)/\(owner.lowercased())"
        }
        return host
    }

    @concurrent
    func stories(_ source: StoryListSource, cursor: PageCursor? = nil) async throws -> StoryPage {
        switch source {
        case .feed(let kind):
            return try await feed(kind, cursor: cursor)
        case .submitted(let user):
            let page: Int = if case .page(let p) = cursor { p } else { 0 }
            let results = try await algolia(query: "", tags: "story,author_\(user)", sort: .date, page: page)
            return StoryPage(stories: results.stories, next: results.hasMore ? .page(page + 1) : nil)
        case .favorites, .upvoted, .hidden:
            let url: URL = if case .url(let u) = cursor { u } else { Self.url(source.webPath ?? "news") }
            let (html, final) = try await fetchHTML(url)
            return HNParser.storyPage(html, baseURL: final)
        }
    }

    private func feed(_ kind: FeedKind, cursor: PageCursor?) async throws -> StoryPage {
        // Signed in: HN's page has the 30 stories *and* your vote state in one gzip'd request
        // (~6 KB). Reading the API too would only duplicate it.
        if Self.sessionCookie != nil {
            let url: URL? = switch cursor {
            case nil: Self.url(kind.webPath)
            case .url(let next): next
            default: nil   // signed in mid-session: keep paging through the API list
            }
            if let url, let (html, final) = try? await fetchHTML(url) {
                let page = HNParser.storyPage(html, baseURL: final)
                if !page.stories.isEmpty { return page }
            }
        }

        // Signed out: the ranked id list from the API, then the page's stories in one Algolia request.
        let allIDs: [Int]
        let offset: Int
        if case .ids(let ids, let o) = cursor {
            allIDs = ids
            offset = o
        } else {
            allIDs = try await decode([Int].self, from: Self.api.appending(path: "\(kind.apiName).json"))
            offset = 0
        }
        let slice = Array(allIDs.dropFirst(offset).prefix(Self.pageSize))
        // Algolia doesn't index job posts, so the Jobs feed goes straight to the API.
        var stories = try await stories(ids: slice, useAlgolia: kind != .jobs)
        for i in stories.indices {
            stories[i].rank = offset + i + 1
        }
        let nextOffset = offset + slice.count
        return StoryPage(stories: stories, next: nextOffset < allIDs.count ? .ids(allIDs, offset: nextOffset) : nil)
    }

    /// Stories for a list of ids, in that order. One Algolia request instead of one API request
    /// per story (31 → 2 requests per page, and no burst of new connections). Algolia's scores and
    /// comment counts track the API within a point or two; anything it lacks (job posts, polls,
    /// stories from the last few seconds) comes from the API.
    private func stories(ids: [Int], useAlgolia: Bool = true) async throws -> [Story] {
        guard !ids.isEmpty else { return [] }
        var found: [Int: Story] = [:]
        let tags = "story,(" + ids.map { "story_\($0)" }.joined(separator: ",") + ")"
        if useAlgolia, let batch = try? await algolia(query: "", tags: tags, sort: .relevance, page: 0, hitsPerPage: ids.count) {
            for story in batch.stories { found[story.id] = story }
        }
        let missing = ids.filter { found[$0] == nil }
        if !missing.isEmpty {
            for item in try await items(missing) where item.deleted != true && item.dead != true {
                found[item.id] = item.story
            }
        }
        return ids.compactMap { found[$0] }
    }

    /// Author and a plain-text snippet for each id (comments only; stories are skipped).
    @concurrent
    func parentPreviews(for ids: [Int]) async -> [Int: ParentPreview] {
        guard !ids.isEmpty, let fetched = try? await items(ids) else { return [:] }
        var previews: [Int: ParentPreview] = [:]
        for item in fetched where item.type == "comment" {
            let isGone = item.deleted == true || item.dead == true
            previews[item.id] = ParentPreview(
                author: item.by,
                text: isGone ? "[deleted]" : HTML.plainText(item.text ?? "")
            )
        }
        return previews
    }

    @concurrent
    func comments(_ source: CommentListSource, cursor: PageCursor? = nil) async throws -> CommentPage {
        switch source {
        case .byUser(let user):
            let page: Int = if case .page(let p) = cursor { p } else { 0 }
            let results = try await algolia(query: "", tags: "comment,author_\(user)", sort: .date, page: page)
            return CommentPage(comments: results.comments, next: results.hasMore ? .page(page + 1) : nil)
        case .threads, .favorites, .upvoted:
            let url: URL = if case .url(let u) = cursor { u } else { Self.url(source.webPath ?? "news") }
            let (html, final) = try await fetchHTML(url)
            return HNParser.commentPage(html, baseURL: final)
        }
    }

    // MARK: Threads — Algolia tree + API ranking + website overlay

    nonisolated struct AlgoliaNode: Decodable, Sendable {
        let id: Int
        let type: String?
        let author: String?
        let created_at_i: TimeInterval?
        let title: String?
        let url: String?
        let text: String?
        let points: Int?
        let parent_id: Int?
        let story_id: Int?
        let children: [AlgoliaNode]
        let options: [AlgoliaNode]?
    }

    /// Loads a whole discussion in one Algolia request, ranks it the way HN does,
    /// and (when signed in) merges in vote state from the website.
    @concurrent
    func thread(id: Int) async throws -> ThreadPage {
        // Signed in: HN's page already has the ranked tree, the text and your votes, gzip'd
        // (~13 KB for 60 comments vs ~29 KB uncompressed from Algolia), so it's all we need.
        let webPage = Self.sessionCookie != nil ? await webThread(id: id) : nil
        if let page = webPage?.0, Self.isComplete(page) { return page }

        async let algoliaTree = try? decode(AlgoliaNode.self, from: URL(string: "https://hn.algolia.com/api/v1/items/\(id)")!)
        async let apiRoot = try? item(id)

        guard let tree = await algoliaTree else {
            // Algolia is down or hasn't indexed the item yet: fall back to the website.
            if let page = webPage { return page.0 }
            if let page = await webThread(id: id, requireSignIn: false) { return page.0 }
            throw HNError.notFound
        }
        let root = await apiRoot

        // Rank: the website order when we have it (exact), else the API's ranked `kids` for top level.
        var rank: [Int: Int] = [:]
        if let webPage {
            for (i, c) in webPage.0.comments.enumerated() { rank[c.id] = i }
        } else {
            for (i, kid) in (root?.kids ?? []).enumerated() { rank[kid] = i }
        }
        let actions = webPage?.1 ?? [:]

        var comments: [Comment] = []
        flatten(tree.children, depth: 0, parent: tree.id, rank: rank, actions: actions, into: &comments)

        // Algolia indexes with a short delay; keep comments only the website has (like one you just posted).
        if let webComments = webPage?.0.comments {
            let known = Set(comments.map(\.id))
            for webComment in webComments where !known.contains(webComment.id) {
                if let parent = webComment.parentID, let i = comments.firstIndex(where: { $0.id == parent }) {
                    var placed = webComment
                    placed.depth = comments[i].depth + 1
                    comments.insert(placed, at: i + 1)
                } else if webComment.depth == 0 {
                    comments.insert(webComment, at: 0)
                }
            }
        }

        var page = ThreadPage(story: nil, rootComment: nil, comments: comments, replyForm: nil, parentID: tree.parent_id)
        if tree.type == "comment" {
            var comment = makeComment(tree, depth: 0, parent: tree.parent_id)
            comment.storyID = tree.story_id
            if let a = actions[tree.id] { comment.actions.merge(a) }
            page.rootComment = comment
        } else {
            var story = root?.story ?? Story(
                id: tree.id,
                title: HTML.decodeEntities(tree.title ?? ""),
                url: tree.url.flatMap(URL.init(string:)),
                score: tree.points,
                author: tree.author,
                date: tree.created_at_i.map { Date(timeIntervalSince1970: $0) },
                commentCount: comments.count,
                text: tree.text.map { HTML.attributed($0) }
            )
            if let webStory = webPage?.0.story {
                story.score = webStory.score ?? story.score
            }
            if let a = actions[tree.id] { story.actions.merge(a) }
            story.pollOptions = (tree.options ?? []).map { option in
                PollOption(
                    id: option.id,
                    text: HTML.plainText(option.text ?? ""),
                    score: option.points ?? 0,
                    actions: actions[option.id] ?? ItemActions()
                )
            }
            page.story = story
        }
        return page
    }

    /// A website thread we can show as-is (parsing didn't silently drop the comments).
    private static func isComplete(_ page: ThreadPage) -> Bool {
        if let story = page.story {
            return (story.commentCount ?? 0) == 0 || !page.comments.isEmpty
        }
        return page.rootComment != nil
    }

    private func flatten(_ nodes: [AlgoliaNode], depth: Int, parent: Int, rank: [Int: Int], actions: [Int: ItemActions], into out: inout [Comment]) {
        let ordered = nodes.enumerated().sorted { a, b in
            (rank[a.element.id] ?? Int.max, a.offset) < (rank[b.element.id] ?? Int.max, b.offset)
        }
        for (_, node) in ordered {
            let isDeleted = node.author == nil && node.text == nil
            if isDeleted && node.children.isEmpty { continue }
            var comment = makeComment(node, depth: depth, parent: parent)
            if let a = actions[node.id] { comment.actions.merge(a) }
            out.append(comment)
            flatten(node.children, depth: depth + 1, parent: node.id, rank: rank, actions: actions, into: &out)
        }
    }

    private func makeComment(_ node: AlgoliaNode, depth: Int, parent: Int?) -> Comment {
        let html = node.text ?? ""
        let isDeleted = node.author == nil && node.text == nil
        return Comment(
            id: node.id,
            depth: depth,
            parentID: parent,
            author: node.author,
            date: node.created_at_i.map { Date(timeIntervalSince1970: $0) },
            text: isDeleted ? AttributedString("[deleted]") : HTML.attributed(html),
            plainText: HTML.plainText(html),
            isDeleted: isDeleted,
            storyID: node.story_id
        )
    }

    /// The website version of a thread. Only fetched when signed in, unless used as a fallback.
    private func webThread(id: Int, requireSignIn: Bool = true) async -> (ThreadPage, [Int: ItemActions])? {
        guard !requireSignIn || Self.sessionCookie != nil else { return nil }
        guard let (html, url) = try? await fetchHTML(Self.url("item?id=\(id)")),
              !html.contains("No such item.")
        else { return nil }
        var actions = HNParser.actionLinks(in: html)
        var (page, next) = HNParser.threadPage(html, baseURL: url)
        var fetched = 1
        while let nextURL = next, fetched < 12, let (more, moreURL) = try? await fetchHTML(nextURL) {
            let (morePage, following) = HNParser.threadPage(more, baseURL: moreURL)
            page.comments += morePage.comments
            actions.merge(HNParser.actionLinks(in: more)) { old, new in var o = old; o.merge(new); return o }
            next = following
            fetched += 1
        }
        return (page, actions)
    }

    /// Fresh action links for one item (used when a list didn't include the link we need).
    @concurrent
    func actions(for id: Int) async throws -> ItemActions {
        guard Self.sessionCookie != nil else { throw HNError.notLoggedIn }
        let (html, _) = try await fetchHTML(Self.url("item?id=\(id)"))
        return HNParser.actionLinks(in: html)[id] ?? ItemActions()
    }

    @concurrent
    func user(_ id: String) async throws -> UserProfile {
        struct Raw: Decodable { let id: String; let created: TimeInterval; let karma: Int; let about: String? }
        guard let raw = try await decode(Raw?.self, from: Self.api.appending(path: "user/\(id).json")) else {
            throw HNError.notFound
        }
        return UserProfile(
            id: raw.id,
            created: Date(timeIntervalSince1970: raw.created),
            karma: raw.karma,
            about: raw.about.map { HTML.attributed($0) }
        )
    }

    // MARK: Search (Algolia)

    nonisolated enum SearchKind: String, CaseIterable, Sendable { case stories = "story", comments = "comment" }
    nonisolated enum SearchSort: String, CaseIterable, Sendable { case relevance, date }

    nonisolated struct SearchResults: Sendable {
        var stories: [Story] = []
        var comments: [Comment] = []
        var page: Int
        var hasMore: Bool
    }

    @concurrent
    func search(_ query: String, kind: SearchKind, sort: SearchSort, page: Int) async throws -> SearchResults {
        try await algolia(query: query, tags: kind.rawValue, sort: sort, page: page)
    }

    private func algolia(query: String, tags: String, sort: SearchSort, page: Int, hitsPerPage: Int = HNClient.pageSize) async throws -> SearchResults {
        struct Response: Decodable {
            struct Hit: Decodable {
                let objectID: String
                let _tags: [String]?
                let title: String?
                let url: String?
                let author: String?
                let points: Int?
                let num_comments: Int?
                let created_at_i: TimeInterval?
                let story_id: Int?
                let story_title: String?
                let comment_text: String?
                let story_text: String?
                let parent_id: Int?
            }
            let hits: [Hit]
            let page: Int
            let nbPages: Int
        }
        let endpoint = sort == .date ? "search_by_date" : "search"
        var comps = URLComponents(string: "https://hn.algolia.com/api/v1/\(endpoint)")!
        comps.queryItems = [
            .init(name: "query", value: query),
            .init(name: "tags", value: tags),
            .init(name: "page", value: String(page)),
            .init(name: "hitsPerPage", value: String(hitsPerPage)),
            // Only what we decode, and no highlight/snippet copies of every field: ~80% smaller.
            .init(name: "attributesToRetrieve", value: "title,url,author,points,num_comments,created_at_i,story_id,story_title,comment_text,story_text,parent_id"),
            .init(name: "attributesToHighlight", value: "[]"),
            .init(name: "attributesToSnippet", value: "[]"),
        ]
        let response = try await decode(Response.self, from: comps.url!)
        var results = SearchResults(page: response.page, hasMore: response.page + 1 < response.nbPages)
        for hit in response.hits {
            guard let id = Int(hit.objectID) else { continue }
            let date = hit.created_at_i.map { Date(timeIntervalSince1970: $0) }
            if let html = hit.comment_text {
                results.comments.append(Comment(
                    id: id,
                    depth: 0,
                    parentID: hit.parent_id,
                    author: hit.author,
                    date: date,
                    text: HTML.attributed(html),
                    plainText: HTML.plainText(html),
                    storyID: hit.story_id,
                    storyTitle: hit.story_title
                ))
            } else {
                let url = hit.url.flatMap { $0.isEmpty ? nil : URL(string: $0) }
                results.stories.append(Story(
                    id: id,
                    title: hit.title ?? "Untitled",
                    url: url,
                    site: url.flatMap(Self.displaySite),
                    score: hit.points,
                    author: hit.author,
                    date: date,
                    commentCount: hit.num_comments ?? 0,
                    text: hit.story_text.map { HTML.attributed($0) }
                ))
            }
        }
        return results
    }

    // MARK: Account

    static var sessionCookie: HTTPCookie? {
        HTTPCookieStorage.shared.cookies(for: base)?.first { $0.name == cookieName && !$0.value.isEmpty }
    }

    @concurrent
    func login(username: String, password: String) async throws -> HTTPCookie {
        Self.clearSessionCookies()
        let (html, _) = try await post("login", fields: ["acct": username, "pw": password, "goto": "news"])
        if let cookie = Self.sessionCookie { return cookie }
        if html.contains("recaptcha") || html.contains("Validation required") { throw HNError.captchaRequired }
        if html.contains("Bad login") { throw HNError.badLogin }
        throw HNError.server(HNParser.errorMessage(in: html) ?? "Sign-in failed.")
    }

    @concurrent
    func createAccount(username: String, password: String) async throws -> HTTPCookie {
        Self.clearSessionCookies()
        let (html, _) = try await post("login", fields: ["acct": username, "pw": password, "creating": "t", "goto": "news"])
        if let cookie = Self.sessionCookie { return cookie }
        if html.contains("recaptcha") || html.contains("Validation required") { throw HNError.captchaRequired }
        throw HNError.server(HNParser.errorMessage(in: html) ?? HTML.plainText(html.after("<body>") ?? "Couldn't create the account."))
    }

    @concurrent
    func logout() async {
        if let (html, _) = try? await fetchHTML(Self.url("news")),
           let href = html.slice(from: "id=\"logout\" href=\"", to: "\"") {
            _ = try? await fetchHTML(Self.url(HTML.decodeEntities(href)))
        }
        Self.clearSessionCookies()
    }

    static func install(cookieValue: String) {
        let cookie = HTTPCookie(properties: [
            .name: cookieName,
            .value: cookieValue,
            .domain: "news.ycombinator.com",
            .path: "/",
            .secure: "TRUE",
            .expires: Date.now.addingTimeInterval(60 * 60 * 24 * 365 * 5),
        ])
        if let cookie { HTTPCookieStorage.shared.setCookie(cookie) }
    }

    static func clearSessionCookies() {
        for cookie in HTTPCookieStorage.shared.cookies(for: base) ?? [] where cookie.name == cookieName {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }

    // MARK: Actions

    /// Follows one of HN's action links (`fave?…&auth=…` etc).
    @concurrent
    func follow(_ href: String) async throws {
        guard Self.sessionCookie != nil else { throw HNError.notLoggedIn }
        let (html, url) = try await fetchHTML(Self.url(href))
        if url.path() == "/login" || html.contains("You have to be logged in") { throw HNError.notLoggedIn }
        if let message = HNParser.errorMessage(in: html), html.count < 2000 { throw HNError.server(message) }
    }

    @concurrent
    func vote(id: Int, how: String, auth: String) async throws {
        try await follow("vote?id=\(id)&how=\(how)&auth=\(auth)&goto=news&js=t")
    }

    /// The reply form (with its `hmac`) for a story or comment.
    @concurrent
    func replyForm(for id: Int) async throws -> HNForm {
        guard Self.sessionCookie != nil else { throw HNError.notLoggedIn }
        let (html, _) = try await fetchHTML(Self.url("item?id=\(id)"))
        if let form = HNParser.form(in: html, action: "comment") { return form }
        if let message = HNParser.errorMessage(in: html) { throw HNError.server(message) }
        throw HNError.actionUnavailable
    }

    @concurrent
    func postComment(form: HNForm, text: String) async throws {
        var fields = form.fields
        fields["text"] = text
        let (html, url) = try await post("comment", fields: fields)
        try Self.checkSubmission(html: html, url: url, failurePaths: ["/comment", "/reply"])
    }

    @concurrent
    func editForm(for id: Int) async throws -> HNForm {
        let (html, _) = try await fetchHTML(Self.url("edit?id=\(id)"))
        guard let form = HNParser.form(in: html, action: "xedit") else {
            throw HNError.server(HNParser.errorMessage(in: html) ?? "This comment can no longer be edited.")
        }
        return form
    }

    @concurrent
    func submitEdit(form: HNForm, text: String) async throws {
        var fields = form.fields
        fields["text"] = text
        let (html, url) = try await post("xedit", fields: fields)
        try Self.checkSubmission(html: html, url: url, failurePaths: ["/xedit"])
    }

    @concurrent
    func delete(id: Int) async throws {
        let (html, _) = try await fetchHTML(Self.url("delete-confirm?id=\(id)&goto=news"))
        guard var form = HNParser.form(in: html, action: "xdelete") else {
            throw HNError.server(HNParser.errorMessage(in: html) ?? "This comment can no longer be deleted.")
        }
        form.fields["d"] = "Yes"
        let (resultHTML, url) = try await post("xdelete", fields: form.fields)
        try Self.checkSubmission(html: resultHTML, url: url, failurePaths: ["/xdelete"])
    }

    @concurrent
    func submit(title: String, url link: String, text: String) async throws {
        guard Self.sessionCookie != nil else { throw HNError.notLoggedIn }
        let (page, _) = try await fetchHTML(Self.url("submit"))
        guard var form = HNParser.form(in: page, action: "r") else { throw HNError.notLoggedIn }
        form.fields["title"] = title
        form.fields["url"] = link
        form.fields["text"] = text
        let (html, url) = try await post("r", fields: form.fields)
        try Self.checkSubmission(html: html, url: url, failurePaths: ["/r", "/submit", "/submitlink"])
    }

    private static func checkSubmission(html: String, url: URL, failurePaths: [String]) throws {
        if url.path() == "/login" { throw HNError.notLoggedIn }
        if let message = HNParser.errorMessage(in: html) { throw HNError.server(message) }
        if failurePaths.contains(url.path()) {
            let text = HTML.plainText(html.after("<body>") ?? html[...])
            throw HNError.server(text.isEmpty || text.count > 300 ? "Hacker News didn't accept that." : text)
        }
    }
}

nonisolated extension String {
    var formEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.*")))?
            .replacingOccurrences(of: "%20", with: "+") ?? self
    }
}
