import Foundation

/// Scrapes news.ycombinator.com pages. HN's markup is regular and stable enough
/// that plain string scanning is both faster and simpler than a DOM parser.
nonisolated enum HNParser {

    // MARK: Pages

    static func storyPage(_ html: String, baseURL: URL) -> StoryPage {
        let actions = actionLinks(in: html)
        let chunks = html.components(separatedBy: "<tr class=\"athing").dropFirst()
        let stories = chunks.compactMap { chunk -> Story? in
            let trimmed = chunk.before("<tr class=\"spacer\"").before("class=\"morespace\"")
            guard var story = parseStory(trimmed) else { return nil }
            if let a = actions[story.id] { story.actions.merge(a) }
            return story
        }
        return StoryPage(stories: stories, next: moreLink(in: html, baseURL: baseURL).map(PageCursor.url))
    }

    static func commentPage(_ html: String, baseURL: URL) -> CommentPage {
        let actions = actionLinks(in: html)
        var comments = parseCommentTree(html)
        for i in comments.indices {
            if let a = actions[comments[i].id] { comments[i].actions.merge(a) }
        }
        return CommentPage(comments: comments, next: moreLink(in: html, baseURL: baseURL).map(PageCursor.url))
    }

    static func threadPage(_ html: String, baseURL: URL) -> (ThreadPage, next: URL?) {
        let actions = actionLinks(in: html)
        let parts = html.components(separatedBy: "class=\"comment-tree\"")
        let top = parts[0]
        let tree = parts.count > 1 ? parts[1] : ""

        var story: Story?
        var root: Comment?
        var parentID: Int?
        if let fat = top.after("class=\"fatitem\"") {
            if fat.contains("class=\"titleline\""), let chunk = fat.after("<tr class=\"athing") {
                story = parseStory(chunk.before("<form"))
                if let text = fat.slice(from: "<div class=\"toptext\">", to: "</div>"), !text.isEmpty {
                    story?.text = HTML.attributed(text)
                }
                if let id = story?.id, let a = actions[id] { story?.actions.merge(a) }
                story?.pollOptions = pollOptions(in: fat.after("class=\"toptext\"") ?? "", actions: actions)
            } else if let chunk = fat.after("<tr class=\"athing") {
                root = parseComment(chunk.before("<form"))
                if let id = root?.id, let a = actions[id] { root?.actions.merge(a) }
                if let navs = chunk.slice(from: "class=\"navs\"", to: "</span></span>"),
                   let p = navs.slice(from: "href=\"item?id=", to: "\">parent<") {
                    parentID = Int(p)
                }
            }
        }

        var comments = parseCommentTree(tree)
        for i in comments.indices {
            if let a = actions[comments[i].id] { comments[i].actions.merge(a) }
        }

        let page = ThreadPage(
            story: story,
            rootComment: root,
            comments: comments,
            replyForm: form(in: top, action: "comment"),
            parentID: parentID
        )
        return (page, moreLink(in: html, baseURL: baseURL))
    }

    /// The `user?id=` link HN shows in the top bar when signed in.
    static func loggedInUser(_ html: String) -> String? {
        html.slice(from: "id=\"me\" href=\"user?id=", to: "\"").map { String($0) }
    }

    // MARK: Items

    static func parseStory(_ chunk: some StringProtocol) -> Story? {
        guard let idText = chunk.slice(from: "id=\"", to: "\"") ?? chunk.slice(from: "id='", to: "'"),
              let id = Int(idText),
              let titleLine = chunk.after("<span class=\"titleline\">"),
              let anchor = titleLine.slice(from: "<a ", to: "</a>"),
              let href = HTML.attribute("href", in: anchor.before(">")),
              let titleHTML = anchor.after(">")
        else { return nil }

        let decodedHref = HTML.decodeEntities(href)
        let url: URL? = decodedHref.hasPrefix("item?id=")
            ? nil
            : URL(string: decodedHref, relativeTo: HNClient.base)?.absoluteURL

        let subtext = chunk.after("class=\"subtext\"") ?? ""
        // `<span class="score" id="score_123">404 points</span>`: take the number after the tag,
        // not the digits in the id.
        let score = subtext.slice(from: "class=\"score\"", to: " point")
            .flatMap { $0.after(">") }
            .flatMap { Int($0) }
        let author = subtext.slice(from: "href=\"user?id=", to: "\"").map { String($0) }

        return Story(
            id: id,
            rank: chunk.slice(from: "<span class=\"rank\">", to: ".</span>").flatMap { Int($0) },
            title: HTML.plainText(titleHTML),
            url: url,
            site: chunk.slice(from: "<span class=\"sitestr\">", to: "</span>").map { HTML.decodeEntities($0) },
            score: score,
            author: author,
            date: parseAge(subtext),
            commentCount: commentCount(in: subtext),
            text: nil,
            isDead: chunk.contains("[dead]"),
            isFlagged: chunk.contains("[flagged]")
        )
    }

    static func parseCommentTree(_ html: some StringProtocol) -> [Comment] {
        var comments: [Comment] = []
        var stack: [(depth: Int, id: Int)] = []
        for chunk in html.components(separatedBy: "<tr class=\"athing comtr").dropFirst() {
            guard var comment = parseComment(chunk) else { continue }
            while let last = stack.last, last.depth >= comment.depth { stack.removeLast() }
            // Inside a page's tree the parent is the comment above; at top level (e.g. on
            // /threads) keep the parent from the comment's own "parent" link.
            comment.parentID = stack.last?.id ?? comment.parentID
            stack.append((comment.depth, comment.id))
            comments.append(comment)
        }
        return comments
    }

    static func parseComment(_ chunk: some StringProtocol) -> Comment? {
        guard let idText = chunk.slice(from: "id=\"", to: "\""), let id = Int(idText) else { return nil }
        let depth = chunk.slice(from: "indent=\"", to: "\"").flatMap { Int($0) } ?? 0
        let head = chunk.slice(from: "class=\"comhead\"", to: "<div class=\"comment\">") ?? ""
        let author = head.slice(from: "href=\"user?id=", to: "\"").map { String($0) }

        var html = ""
        var colorClass = "c00"
        if let range = chunk.range(of: "class=\"commtext") {
            let tagStart = chunk[..<range.lowerBound].range(of: "<", options: .backwards)
            let tagName = tagStart.map { chunk[chunk.index(after: $0.lowerBound)..<range.lowerBound].trimmingCharacters(in: .whitespaces) } ?? "div"
            let rest = chunk[range.upperBound...]
            colorClass = String(rest.prefix(while: { $0 != "\"" }).trimmingCharacters(in: .whitespaces))
            if let bodyStart = rest.firstIndex(of: ">") {
                html = String(rest[rest.index(after: bodyStart)...].before("</\(tagName)>"))
            }
        } else if let body = chunk.slice(from: "<div class=\"comment\">", to: "</div>") {
            html = String(body)
        }

        let plain = HTML.plainText(html)
        let isDeleted = author == nil || plain == "[deleted]"
        var storyID: Int?
        var storyTitle: String?
        if let onStory = head.after("class=\"onstory\""), let anchor = onStory.slice(from: "<a ", to: "</a>") {
            storyID = anchor.slice(from: "item?id=", to: "\"").flatMap { Int($0) }
            storyTitle = HTML.attribute("title", in: anchor.before(">")).map(HTML.decodeEntities)
                ?? anchor.after(">").map { HTML.plainText($0) }
        }

        var parentID: Int?
        if let r = head.range(of: "\">parent</a>") {
            let before = head[..<r.lowerBound]
            if let idStart = before.range(of: "item?id=", options: .backwards) {
                parentID = Int(before[idStart.upperBound...])
            }
        }

        return Comment(
            id: id,
            depth: depth,
            parentID: parentID,
            author: author,
            date: parseAge(head),
            text: isDeleted && plain.isEmpty ? AttributedString("[deleted]") : HTML.attributed(html),
            plainText: plain,
            fade: fade(for: colorClass),
            isDeleted: isDeleted,
            isDead: head.contains("[dead]") || head.contains("[flagged]"),
            storyID: storyID,
            storyTitle: storyTitle
        )
    }

    /// Poll options: `<tr class="athing" id=…>` rows after the story text, each with its text
    /// in `td.comment` and its own `score_<id>` span.
    static func pollOptions(in html: some StringProtocol, actions: [Int: ItemActions]) -> [PollOption] {
        html.before("<form").components(separatedBy: "<tr class=\"athing\" id=\"").dropFirst().compactMap { chunk in
            guard let id = Int(chunk.prefix(while: \.isNumber)),
                  let body = chunk.slice(from: "<td class=\"comment\">", to: "</td>")
            else { return nil }
            let score = chunk.slice(from: "id=\"score_\(id)\">", to: " point").flatMap { Int($0) } ?? 0
            return PollOption(id: id, text: HTML.plainText(body), score: score, actions: actions[id] ?? ItemActions())
        }
    }

    // MARK: Action links

    /// Collects every vote/favorite/hide/flag/edit/delete/reply link on the page, keyed by item id.
    static func actionLinks(in html: String) -> [Int: ItemActions] {
        var result: [Int: ItemActions] = [:]
        let prefixes = ["vote?", "fave?", "hide?", "flag?", "edit?", "delete-confirm?", "reply?"]
        var search = html[...]
        while let r = search.range(of: "href=") {
            let afterEq = search[r.upperBound...]
            guard let quote = afterEq.first, quote == "\"" || quote == "'" else {
                search = afterEq
                continue
            }
            let valueStart = afterEq.index(after: afterEq.startIndex)
            guard let valueEnd = afterEq[valueStart...].firstIndex(of: quote) else { break }
            let href = afterEq[valueStart..<valueEnd]
            search = afterEq[valueEnd...]

            guard prefixes.contains(where: { href.hasPrefix($0) }) else { continue }
            let decoded = HTML.decodeEntities(href)
            let label: String = {
                guard let gt = search.firstIndex(of: ">") else { return "" }
                return String(search[search.index(after: gt)...].prefix(while: { $0 != "<" }))
            }()
            guard let comps = URLComponents(string: "https://x/" + decoded) else { continue }
            let query = Dictionary(
                (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                uniquingKeysWith: { a, _ in a }
            )
            guard let id = query["id"].flatMap(Int.init) else { continue }
            let auth = query["auth"]
            let undo = query["un"] == "t"
            var a = result[id] ?? ItemActions()

            switch comps.path {
            case "/vote":
                guard let auth else { break }
                a.voteAuth = auth
                switch query["how"] {
                case "down": a.canDownvote = true
                case "un": a.vote = label.contains("undown") ? .down : .up
                default: break
                }
            case "/fave":
                guard auth != nil else { break }
                a.links[undo ? "unfave" : "fave"] = decoded
                a.favorited = undo
            case "/hide":
                guard auth != nil else { break }
                a.links[undo ? "unhide" : "hide"] = decoded
                a.hidden = undo
            case "/flag":
                guard auth != nil else { break }
                a.links[undo ? "unflag" : "flag"] = decoded
                a.flagged = undo
            case "/edit":
                a.links["edit"] = decoded
            case "/delete-confirm":
                a.links["delete"] = decoded
            case "/reply":
                a.links["reply"] = decoded
            default:
                break
            }
            result[id] = a
        }
        return result
    }

    // MARK: Forms

    /// Finds `<form action="…">` (with or without a leading slash) and collects its inputs.
    static func form(in html: String, action: String) -> HNForm? {
        var match: Substring?
        for candidate in ["action=\"\(action)\"", "action=\"/\(action)\"", "action='\(action)'", "action='/\(action)'"] {
            if let body = html.after(candidate) {
                match = body
                break
            }
        }
        guard let body = match?.before("</form>") else { return nil }

        var fields: [String: String] = [:]
        var rest = body[...]
        while let r = rest.range(of: "<input") {
            let tagBody = rest[r.upperBound...].prefix(while: { $0 != ">" })
            if let name = HTML.attribute("name", in: tagBody),
               HTML.attribute("type", in: tagBody) == "hidden" {
                fields[name] = HTML.decodeEntities(HTML.attribute("value", in: tagBody) ?? "")
            }
            rest = rest[r.upperBound...]
        }
        let textarea = body.after("<textarea").flatMap { $0.after(">") }.map { HTML.decodeEntities($0.before("</textarea>")) }
        return HNForm(action: action, fields: fields, textareaValue: textarea)
    }

    /// HN error pages are bare text; pull out something readable.
    static func errorMessage(in html: String) -> String? {
        let known = [
            "You're posting too fast", "Please slow down", "Sorry, we're not able to serve your requests this quickly",
            "Bad login", "That comment is too long", "Please try again", "You have to be logged in",
            "Can't make that vote", "Validation required",
        ]
        if let hit = known.first(where: { html.contains($0) }) {
            let body = html.after("<body>").map { HTML.plainText($0) } ?? hit
            return body.count < 300 ? body : hit
        }
        return nil
    }

    // MARK: Small pieces

    static func moreLink(in html: String, baseURL: URL) -> URL? {
        for marker in ["class=\"morelink\"", "class='morelink'"] {
            guard let r = html.range(of: marker) else { continue }
            let head = html[..<r.lowerBound].suffix(400)
            guard let hrefRange = head.range(of: "href=", options: .backwards) else { continue }
            let tag = head[hrefRange.lowerBound...]
            if let href = HTML.attribute("href", in: tag) {
                return URL(string: HTML.decodeEntities(href), relativeTo: baseURL)?.absoluteURL
            }
        }
        return nil
    }

    private static func commentCount(in subtext: some StringProtocol) -> Int? {
        var rest = subtext[...]
        var found: Int?
        while let r = rest.range(of: "</a>") {
            let anchorText = rest[..<r.lowerBound].suffix(while: { $0 != ">" })
            let text = HTML.decodeEntities(anchorText)
            if text.contains("comment") {
                found = Int(text.prefix(while: \.isNumber))
            } else if text == "discuss" {
                found = 0
            }
            rest = rest[r.upperBound...]
        }
        return found
    }

    /// `<span class="age" title="2026-11-23T01:13:51 1763860431">` — the epoch suffix is optional.
    private static func parseAge(_ html: some StringProtocol) -> Date? {
        guard let title = html.slice(from: "class=\"age\" title=\"", to: "\"") else { return nil }
        let parts = title.split(separator: " ")
        if parts.count > 1, let epoch = TimeInterval(parts[1]) {
            return Date(timeIntervalSince1970: epoch)
        }
        guard let iso = parts.first else { return nil }
        let numbers = iso.split(whereSeparator: { $0 == "-" || $0 == "T" || $0 == ":" }).compactMap { Int($0) }
        guard numbers.count >= 6 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.date(from: DateComponents(
            year: numbers[0], month: numbers[1], day: numbers[2],
            hour: numbers[3], minute: numbers[4], second: numbers[5]
        ))
    }

    private static func fade(for colorClass: String) -> Double {
        switch colorClass.lowercased() {
        case "c00": 0
        case "c5a": 0.15
        case "c73": 0.25
        case "c82": 0.32
        case "c88": 0.38
        case "c9c": 0.45
        case "cae": 0.55
        case "cbe": 0.62
        case "cce": 0.68
        case "cdd": 0.75
        default: 0
        }
    }
}

nonisolated extension BidirectionalCollection {
    func suffix(while predicate: (Element) -> Bool) -> SubSequence {
        var i = endIndex
        while i > startIndex {
            let prev = index(before: i)
            guard predicate(self[prev]) else { break }
            i = prev
        }
        return self[i...]
    }
}
