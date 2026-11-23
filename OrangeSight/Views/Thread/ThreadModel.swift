import SwiftUI

struct VisibleComment: Identifiable, Hashable {
    let index: Int
    let id: Int
}

@Observable
final class ThreadModel {
    let id: Int
    var story: Story?
    var rootComment: Comment?
    var parentID: Int?
    var comments: [Comment] = []
    var collapsed: Set<Int> = []
    private(set) var replyCounts: [Int: Int] = [:]
    private(set) var isLoading = false
    private(set) var error: (any Error)?
    private(set) var hasLoaded = false

    init(id: Int) {
        self.id = id
    }

    var opAuthor: String? { story?.author ?? rootComment?.author }

    /// Comments with collapsed subtrees removed.
    var visible: [VisibleComment] {
        var out: [VisibleComment] = []
        out.reserveCapacity(comments.count)
        var hideBelowDepth: Int?
        for (index, comment) in comments.enumerated() {
            if let depth = hideBelowDepth {
                if comment.depth > depth { continue }
                hideBelowDepth = nil
            }
            out.append(VisibleComment(index: index, id: comment.id))
            if collapsed.contains(comment.id) { hideBelowDepth = comment.depth }
        }
        return out
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await HNClient.shared.thread(id: id)
            story = page.story
            rootComment = page.rootComment
            parentID = page.parentID
            comments = page.comments
            recountReplies()
            error = nil
        } catch is CancellationError {
        } catch {
            if !hasLoaded { self.error = error }
        }
        hasLoaded = true
    }

    func toggleCollapse(_ id: Int) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }

    /// Collapses the top-level comment that contains `id`.
    func collapseThread(containing id: Int) {
        guard var index = comments.firstIndex(where: { $0.id == id }) else { return }
        while index > 0 && comments[index].depth > 0 { index -= 1 }
        collapsed.insert(comments[index].id)
    }

    func nextTopLevel(after index: Int) -> Int? {
        comments[(index + 1)...].first { $0.depth == 0 }?.id
    }

    // MARK: Optimistic updates after composing

    func insertReply(_ text: String, parentID: Int, author: String) {
        let reply = Comment(
            id: -Int.random(in: 1...Int(Int32.max)),
            depth: 0,
            parentID: parentID,
            author: author,
            date: .now,
            text: AttributedString(text),
            plainText: text
        )
        if let parentIndex = comments.firstIndex(where: { $0.id == parentID }) {
            var placed = reply
            placed.depth = comments[parentIndex].depth + 1
            comments.insert(placed, at: parentIndex + 1)
        } else {
            comments.insert(reply, at: 0)
        }
        story?.commentCount = (story?.commentCount ?? 0) + 1
        recountReplies()
    }

    func updateText(of id: Int, to text: String) {
        if let i = comments.firstIndex(where: { $0.id == id }) {
            comments[i].text = AttributedString(text)
            comments[i].plainText = text
        } else if rootComment?.id == id {
            rootComment?.text = AttributedString(text)
            rootComment?.plainText = text
        }
    }

    func markDeleted(_ id: Int) {
        guard let i = comments.firstIndex(where: { $0.id == id }) else { return }
        let hasReplies = (replyCounts[id] ?? 0) > 0
        if hasReplies {
            comments[i].text = AttributedString("[deleted]")
            comments[i].isDeleted = true
            comments[i].author = nil
        } else {
            comments.remove(at: i)
        }
        recountReplies()
    }

    /// Refetch a few seconds later so HN has the change.
    func reloadSoon() {
        Task {
            try? await Task.sleep(for: .seconds(3))
            await load()
        }
    }

    private func recountReplies() {
        var counts: [Int: Int] = [:]
        var stack: [(depth: Int, id: Int)] = []
        for comment in comments {
            while let last = stack.last, last.depth >= comment.depth { stack.removeLast() }
            for ancestor in stack { counts[ancestor.id, default: 0] += 1 }
            stack.append((comment.depth, comment.id))
        }
        replyCounts = counts
    }
}
