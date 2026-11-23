import SwiftUI

@Observable
final class StoryListModel {
    let source: StoryListSource
    var stories: [Story] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var error: (any Error)?
    private var cursor: PageCursor?
    private var reachedEnd = false

    init(source: StoryListSource) {
        self.source = source
    }

    func refresh() async {
        cursor = nil
        reachedEnd = false
        await load(replacing: true)
    }

    func loadMoreIfNeeded(after story: Story) async {
        guard !reachedEnd, !isLoading, story.id == stories.last?.id else { return }
        await load(replacing: false)
    }

    private func load(replacing: Bool) async {
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            let page = try await HNClient.shared.stories(source, cursor: cursor)
            if replacing {
                stories = page.stories
            } else {
                let existing = Set(stories.map(\.id))
                stories += page.stories.filter { !existing.contains($0.id) }
            }
            cursor = page.next
            reachedEnd = page.next == nil
            error = nil
        } catch is CancellationError {
        } catch {
            if stories.isEmpty || replacing { self.error = error }
        }
    }
}

/// A story list that owns its model (user lists, favorites, etc.).
struct StoryListView: View {
    @State private var model: StoryListModel

    init(source: StoryListSource) {
        _model = State(initialValue: StoryListModel(source: source))
    }

    var body: some View {
        StoryList(model: model)
    }
}

/// Renders a story list for a model owned elsewhere. The Stories tab swaps models when the
/// feed changes, so the List (and the chip bar attached to it) is never torn down.
struct StoryList: View {
    @Bindable var model: StoryListModel
    /// The system pull-to-refresh is hidden by the Stories tab's chip bar, so that screen
    /// uses a custom one (see `CustomPullToRefresh`).
    var showsRefreshIndicator = false

    /// True while a pull-to-refresh runs; shows a spinner row at the top of the list.
    @State private var isPullRefreshing = false

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if isPullRefreshing {
                    // Its own space between the chip bar and the stories until loading completes.
                    RefreshSpinnerRow()
                }
                if !model.hasLoaded || (model.isLoading && model.stories.isEmpty) {
                    // Skeleton rows while the first page loads.
                    ForEach(Story.placeholders) { story in
                        StoryRow(story: .constant(story), showRank: false)
                    }
                    .redacted(reason: .placeholder)
                    .allowsHitTesting(false)
                }
                ForEach($model.stories) { $story in
                    StoryRow(story: $story, showRank: isFeed) {
                        model.stories.removeAll { $0.id == story.id }
                    }
                    .task { await model.loadMoreIfNeeded(after: story) }
                }
                if model.isLoading && !model.stories.isEmpty {
                    LoadingRow()
                }
            }
            .listStyle(.plain)
            .overlay {
                if model.hasLoaded && model.stories.isEmpty && !model.isLoading {
                    if let error = model.error {
                        ErrorView(error: error) { Task { await model.refresh() } }
                    } else {
                        ContentUnavailableView("Nothing Here", systemImage: "tray")
                    }
                }
            }
            .pullToRefresh(custom: showsRefreshIndicator, isRefreshing: $isPullRefreshing) {
                await model.refresh()
            }
            // A new model (feed switch): start at the top, and load it the first time.
            .onChange(of: ObjectIdentifier(model)) {
                if let first = model.stories.first {
                    proxy.scrollTo(first.id, anchor: .top)
                }
            }
            .task(id: ObjectIdentifier(model)) {
                if !model.hasLoaded { await model.refresh() }
            }
        }
        .navigationTitle(model.source.title)
    }

    private var isFeed: Bool {
        if case .feed = model.source { true } else { false }
    }
}

extension View {
    /// The system `.refreshable`, or (`custom`) a pull-to-refresh that doesn't depend on the
    /// system spinner, for screens where a bar over the list hides it.
    @ViewBuilder
    func pullToRefresh(custom: Bool, isRefreshing: Binding<Bool>, action: @escaping @MainActor @Sendable () async -> Void) -> some View {
        if custom {
            modifier(CustomPullToRefresh(isRefreshing: isRefreshing, action: action))
        } else {
            refreshable(action: action)
        }
    }
}

/// The spinner shown at the top of the list while a custom pull-to-refresh runs.
private struct RefreshSpinnerRow: View {
    var body: some View {
        ProgressView()
            .frame(width: 30, height: 30)
            .glassEffect(.regular, in: .circle)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// Watches the scroll view's overscroll and, when released past the threshold, runs `action`
/// with `isRefreshing` set (the list shows a spinner row for that long). While pulling, an arrow
/// follows the gap that opens above the first row.
private struct CustomPullToRefresh: ViewModifier {
    @Binding var isRefreshing: Bool
    let action: @MainActor @Sendable () async -> Void

    @State private var pull: CGFloat = 0

    private let threshold: CGFloat = 70
    private let size: CGFloat = 30

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(0, -(geometry.contentOffset.y + geometry.contentInsets.top))
            } action: { _, overscroll in
                pull = overscroll
            }
            .onScrollPhaseChange { old, new in
                guard old == .interacting, new != .interacting, pull >= threshold, !isRefreshing else { return }
                Task {
                    withAnimation(.snappy) { isRefreshing = true }
                    await action()
                    withAnimation(.snappy) { isRefreshing = false }
                }
            }
            .overlay(alignment: .top) {
                if !isRefreshing && pull > 4 {
                    Image(systemName: "arrow.down")
                        .font(.body.weight(.semibold))
                        .rotationEffect(.degrees(pull >= threshold ? 180 : 0))
                        .animation(.snappy, value: pull >= threshold)
                        .frame(width: size, height: size)
                        .glassEffect(.regular, in: .circle)
                        .offset(y: max(0, pull / 2 - size / 2))
                        .opacity(min(1, pull / 40))
                        .allowsHitTesting(false)
                }
            }
    }
}

extension Story {
    static let placeholders: [Story] = [
        "A reasonably long story title that wraps onto a second line",
        "Short title here",
        "Another headline about software, startups and the web at large",
        "Show HN: A small project I built",
        "Medium length headline for a placeholder row",
        "Ask HN: What are you working on this month?",
        "Yet another title for the loading state",
    ].enumerated().map { index, title in
        Story(id: -index - 1, title: title, site: "example.com", score: 100, author: "placeholder",
              date: .now, commentCount: 42)
    }
}

/// The Stories tab: one of the front-page feeds, chosen from the chip row.
struct FeedTab: View {
    @Environment(AppSettings.self) private var settings
    @State private var kind: FeedKind?
    /// Each feed keeps its stories, so switching back is instant.
    @State private var models: [FeedKind: StoryListModel] = Dictionary(
        uniqueKeysWithValues: FeedKind.allCases.map { ($0, StoryListModel(source: .feed($0))) }
    )

    var body: some View {
        RoutedStack {
            let current = kind ?? settings.defaultFeed
            StoryList(model: models[current]!, showsRefreshIndicator: true)
                // Still used as the back-button label on pushed screens.
                .navigationTitle(current.title)
                // The chip row replaces the navigation bar here: one compact row instead of two.
                .toolbarVisibility(.hidden, for: .navigationBar)
                .safeAreaBar(edge: .top) {
                    FeedPicker(selection: Binding(get: { current }, set: { kind = $0 }))
                }
        }
    }
}

/// Horizontally scrolling chips for the front-page feeds.
struct FeedPicker: View {
    static let chipHeight: CGFloat = 32

    @Binding var selection: FeedKind

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                // No GlassEffectContainer: chips in a shared container refract each other, which
                // tinted the neighbours of the selected (orange) chip.
                Group {
                    HStack(spacing: 6) {
                        ForEach(FeedKind.allCases) { feed in
                            let isSelected = feed == selection
                            Button {
                                // No withAnimation here: it would also animate the list's data swap.
                                selection = feed
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: feed.systemImage)
                                        .imageScale(.small)
                                    Text(feed.title)
                                }
                                .font(.subheadline.weight(isSelected ? .semibold : .medium))
                                .foregroundStyle(isSelected ? .white : .primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .frame(minHeight: Self.chipHeight)
                                .glassEffect(isSelected ? .regular.tint(.hnOrange).interactive() : .regular.interactive(), in: .capsule)
                                // 44pt-tall hit area around the 32pt chip.
                                .padding(.vertical, 6)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            // Draw the selected chip last. Glass refracts whatever is drawn beneath it
                            // (a little past its edge), so a later-drawn neighbour picked up the orange.
                            .zIndex(isSelected ? 1 : 0)
                            .id(feed)
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, 16)
                    .animation(.snappy, value: selection)
                }
            }
            .scrollIndicators(.hidden)
            // Like system bars, cap the chip text so the row stays one line tall.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .onChange(of: selection) { _, new in
                withAnimation { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }
}
