import SwiftUI

@Observable
final class SearchModel {
    var query = ""
    var kind: HNClient.SearchKind = .stories
    var sort: HNClient.SearchSort = .relevance
    var stories: [Story] = []
    var comments: [Comment] = []
    private(set) var isLoading = false
    private(set) var error: (any Error)?
    private(set) var searchedQuery = ""
    private var page = 0
    private var hasMore = false

    func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            stories = []
            comments = []
            searchedQuery = ""
            return
        }
        page = 0
        await load(trimmed, replacing: true)
    }

    func loadMoreIfNeeded(id: Int) async {
        let lastID = kind == .stories ? stories.last?.id : comments.last?.id
        guard hasMore, !isLoading, id == lastID else { return }
        page += 1
        await load(searchedQuery, replacing: false)
    }

    private func load(_ query: String, replacing: Bool) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let results = try await HNClient.shared.search(query, kind: kind, sort: sort, page: page)
            if replacing {
                stories = results.stories
                comments = results.comments
            } else {
                stories += results.stories
                comments += results.comments
            }
            hasMore = results.hasMore
            searchedQuery = query
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error
        }
    }
}

struct SearchTab: View {
    @State private var model = SearchModel()

    var body: some View {
        RoutedStack {
            List {
                switch model.kind {
                case .stories:
                    ForEach($model.stories) { $story in
                        StoryRow(story: $story, showRank: false)
                            .task { await model.loadMoreIfNeeded(id: story.id) }
                    }
                case .comments:
                    ForEach($model.comments) { $comment in
                        CommentRow(comment: $comment, showsContext: true)
                            .task { await model.loadMoreIfNeeded(id: comment.id) }
                    }
                    .environment(\.commentTapOpensThread, true)
                }
                if model.isLoading && !(model.stories.isEmpty && model.comments.isEmpty) {
                    LoadingRow()
                }
            }
            .listStyle(.plain)
            .safeAreaBar(edge: .top) {
                HStack {
                    Picker("Type", selection: $model.kind) {
                        Text("Stories").tag(HNClient.SearchKind.stories)
                        Text("Comments").tag(HNClient.SearchKind.comments)
                    }
                    .pickerStyle(.segmented)
                    Menu {
                        Picker("Sort", selection: $model.sort) {
                            Label("Relevance", systemImage: "sparkles").tag(HNClient.SearchSort.relevance)
                            Label("Newest", systemImage: "clock").tag(HNClient.SearchSort.date)
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Sort")
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .overlay { emptyState }
            .navigationTitle("Search")
            .searchable(text: $model.query, prompt: "Search stories and comments")
            .onSubmit(of: .search) { Task { await model.search() } }
            .onChange(of: model.kind) { Task { await model.search() } }
            .onChange(of: model.sort) { Task { await model.search() } }
            .task(id: model.query) {
                // Search as you type, after a short pause.
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                await model.search()
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let empty = model.kind == .stories ? model.stories.isEmpty : model.comments.isEmpty
        if empty {
            if model.isLoading {
                ProgressView()
            } else if let error = model.error {
                ErrorView(error: error) { Task { await model.search() } }
            } else if model.searchedQuery.isEmpty {
                ContentUnavailableView("Search Hacker News", systemImage: "magnifyingglass",
                                       description: Text("Find stories and comments from all of HN's history."))
            } else {
                ContentUnavailableView.search(text: model.searchedQuery)
            }
        }
    }
}
