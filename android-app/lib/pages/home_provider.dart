import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/backend_transport.dart';
import '../services/home_feed_cache.dart';
import '../services/user_facing_error.dart';

typedef HomepageLoader =
    Future<HomepagePage> Function({int tabType, int offset, String? sessionId});
typedef SearchTabsLoader =
    Future<List<SearchTab>> Function(String query, {int page});
typedef CategorySearchLoader = Future<List<SearchTab>> Function({int offset});

/// Immutable view-model of the home recommendation feed.
class HomeState {
  final List<MediaItem> items;
  final int tabIndex;
  final bool isLoading;
  final bool isLoadMore;
  final bool hasMore;
  final String? error;

  const HomeState({
    this.items = const [],
    this.tabIndex = 0,
    this.isLoading = false,
    this.isLoadMore = false,
    this.hasMore = true,
    this.error,
  });

  HomeState copyWith({
    List<MediaItem>? items,
    int? tabIndex,
    bool? isLoading,
    bool? isLoadMore,
    bool? hasMore,
    String? error,
    bool clearError = false,
  }) {
    return HomeState(
      items: items ?? this.items,
      tabIndex: tabIndex ?? this.tabIndex,
      isLoading: isLoading ?? this.isLoading,
      isLoadMore: isLoadMore ?? this.isLoadMore,
      hasMore: hasMore ?? this.hasMore,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Mutable pagination state owned by exactly one tab.
class _TabFeed {
  List<MediaItem> items = [];
  int offset = 0;
  String? sessionId;
  int searchPage = 0;
  Map<String, int> searchPages = const {};
  Map<String, int> searchOffsets = const {};
  final Set<String> seen = {};
  bool recommendExhausted = false;
  bool hasMore = true;
  bool loaded = false;

  /// The card the user is currently on, reported by the page as it renders
  /// feeds. Persisted with the snapshot so the next cold start can resume from
  /// it (officially the landing cache keeps one video plus its position,
  /// `recordNextVideoData`, and consumes it once on the first response).
  String? lastVid;

  /// Set when a load seeded its list from the snapshot's resume point; the
  /// first network response then appends instead of replacing (official
  /// `onMoreDataLoaded` path, `Te` → `uf`), and is cleared right after.
  String? resumedVid;

  void reset() {
    items = [];
    offset = 0;
    sessionId = null;
    searchPage = 0;
    searchPages = const {};
    searchOffsets = const {};
    seen.clear();
    recommendExhausted = false;
    hasMore = true;
    loaded = false;
    // A cancelled load must not leave its resume intent behind; lastVid is
    // deliberately kept — it tracks the card on screen across refreshes.
    resumedVid = null;
  }
}

class _FetchedFeed {
  final List<MediaItem> items;
  final int? nextOffset;
  final String? sessionId;
  final int searchPage;
  final Map<String, int> searchOffsets;
  final bool searchCanAdvance;
  final bool recommendExhausted;
  final bool hasMore;

  const _FetchedFeed({
    required this.items,
    required this.nextOffset,
    required this.sessionId,
    required this.searchPage,
    this.searchOffsets = const {},
    this.searchCanAdvance = false,
    required this.recommendExhausted,
    required this.hasMore,
  });
}

/// Loads and pages the homepage feeds. Each async operation captures its tab
/// and feed before the first await, so switching tabs can never redirect a
/// late response into a different tab's cache.
class HomeNotifier extends Notifier<HomeState> {
  static const tabs = ['小说'];
  static const tabKinds = {'小说': 'book'};
  static const tabTypes = {'小说': 2};
  final HomepageLoader _homepageLoader;
  final SearchTabsLoader _searchLoader;
  final HomeFeedCache? _feedCache;
  final int initialTabIndex;

  HomeNotifier({
    HomepageLoader? homepageLoader,
    SearchTabsLoader? searchLoader,
    HomeFeedCache? feedCache,
    this.initialTabIndex = 0,
  }) : _feedCache = feedCache ?? HomeFeedCache.instance,
       _homepageLoader = homepageLoader ?? ApiClient.instance.homepagePage,
       _searchLoader =
           searchLoader ??
           ((query, {int page = 1}) =>
               ApiClient.instance.searchTabs(query, page: page, tabType: 3));

  Future<List<SearchTab>> _searchByType(
    String name, {
    int page = 1,
    int offset = 0,
  }) => _searchLoader(name, page: page);

  final Map<int, _TabFeed> _feeds = {};
  int _generation = 0;

  /// In-flight feed request. Cancelled when a newer load supersedes it, when
  /// the tab changes, and on dispose, so leaving the page stops the upstream
  /// work instead of only ignoring its result.
  BackendRequest? _activeRequest;

  /// The category this feed opens on. The home page starts on 全部; a page that
  /// is locked to one channel starts on that channel and never shows the strip.
  @override
  HomeState build() {
    ++_generation;
    // Leaving the page (or rebuilding the provider) stops whatever is in
    // flight instead of only ignoring its result.
    ref.onDispose(() => _activeRequest?.cancel());
    _activeRequest?.cancel();
    _feeds.clear();
    return HomeState(tabIndex: initialTabIndex);
  }

  _TabFeed _feedFor(int tabIndex) => _feeds.putIfAbsent(tabIndex, _TabFeed.new);

  /// Reloads the selected tab from page one.
  ///
  /// A manual refresh (pull-to-refresh, error retry) always replaces the list
  /// (official `SaasClientReqType.Refresh` path). A background first load may
  /// resume from the snapshot's last viewed card: the list is trimmed to start
  /// at that card and the network response is appended after it, so the video
  /// on screen never flips to a different one (official landing-cache flow,
  /// `Se` → `sf(listOf(cache))` + `Te` → `uf` append).
  Future<void> load({bool manualRefresh = false}) async {
    final tabIndex = state.tabIndex;
    final generation = ++_generation;
    final feed = _feedFor(tabIndex)..reset();
    // Stale-while-revalidate: show the last rendered cards while the network
    // refresh runs. The cursors stay reset, so the response replaces page one.
    final snapshot = manualRefresh ? null : _feedCache?.load(tabIndex);
    if (snapshot != null) {
      final resumeIndex = snapshot.lastVid == null
          ? -1
          : snapshot.items.indexWhere((item) => item.id == snapshot.lastVid);
      if (resumeIndex > 0) {
        // Resume from the card the user was last on: earlier cards are
        // dropped, matching the official single-video landing cache.
        feed.items = snapshot.items.sublist(resumeIndex);
        feed.resumedVid = snapshot.lastVid;
        // Seed the reported position too: if the user never swipes this
        // session, the next save keeps the same resume point.
        feed.lastVid = snapshot.lastVid;
      } else if (resumeIndex == 0) {
        // Resume point is already the first card; nothing to trim, but the
        // response must still append instead of replacing the visible card.
        feed.resumedVid = snapshot.lastVid;
        feed.lastVid = snapshot.lastVid;
        feed.items = snapshot.items;
      } else {
        // No resume point (or it fell out of the snapshot): show the full
        // snapshot and let the response replace it wholesale, as before.
        feed.items = snapshot.items;
      }
      if (feed.resumedVid != null) {
        // Every snapshot card counts as seen (the client-side equivalent of
        // the official `filterIds` request parameter): a fresh response that
        // still contains them is deduplicated away on append.
        for (final item in snapshot.items) {
          if (item.id.isNotEmpty) feed.seen.add('${item.kind}:${item.id}');
        }
      }
    }
    state = state.copyWith(
      items: feed.items,
      isLoading: true,
      isLoadMore: false,
      hasMore: true,
      clearError: true,
    );

    _activeRequest?.cancel();
    final request = _activeRequest = BackendRequest();

    try {
      final fetched = await ApiClient.instance.withCancellation(
        request,
        () => _loadInitial(tabIndex),
      );
      if (!ref.mounted ||
          generation != _generation ||
          state.tabIndex != tabIndex) {
        return;
      }
      final resume = feed.resumedVid != null;
      feed.resumedVid = null;
      _applyFetched(feed, fetched, replace: !resume);
      state = state.copyWith(
        items: feed.items,
        isLoading: false,
        isLoadMore: false,
        hasMore: feed.hasMore,
      );
      // 上报只在翻页时发生：看第一张卡没滑动就没有 lastVid——兜底用
      // 当前列表首卡（它就是本次会话实际展示的第一张），让续接链在
      // 下一次冷启动成立。
      final savedVid =
          feed.lastVid ?? (feed.items.isEmpty ? null : feed.items.first.id);
      unawaited(
        _feedCache?.save(
          tabIndex,
          feed.items,
          hasMore: feed.hasMore,
          lastVid: savedVid,
        ),
      );
    } catch (error) {
      if (!ref.mounted ||
          generation != _generation ||
          state.tabIndex != tabIndex) {
        return;
      }
      feed.hasMore = false;
      // The seeded snapshot (or nothing, on a cold start) stays on screen;
      // the error surface only takes over when there is nothing to show.
      state = state.copyWith(
        error: userFacingError(error),
        isLoading: false,
        isLoadMore: false,
        hasMore: false,
      );
    }
  }

  /// Restores a cached tab immediately. Incrementing the generation happens
  /// even on a cache hit, which invalidates requests started by the old tab.
  void selectTab(int index) {
    if (index == state.tabIndex || index < 0 || index >= tabs.length) return;
    ++_generation;
    _activeRequest?.cancel();
    final cached = _feeds[index];
    state = state.copyWith(
      tabIndex: index,
      items: cached?.items ?? const [],
      isLoading: false,
      isLoadMore: false,
      hasMore: cached?.hasMore ?? true,
      clearError: true,
    );
    if (cached == null || !cached.loaded) load();
  }

  /// Appends the next page to the selected feed.
  Future<void> loadMore() async {
    if (state.isLoading || state.isLoadMore || !state.hasMore) return;
    final tabIndex = state.tabIndex;
    final generation = _generation;
    final feed = _feedFor(tabIndex);
    state = state.copyWith(isLoadMore: true, clearError: true);

    _activeRequest?.cancel();
    final request = _activeRequest = BackendRequest();

    try {
      final fetched = await ApiClient.instance.withCancellation(
        request,
        () => _loadNext(tabIndex, feed),
      );
      if (!ref.mounted ||
          generation != _generation ||
          state.tabIndex != tabIndex) {
        return;
      }
      _applyFetched(feed, fetched, replace: false);
      state = state.copyWith(
        items: feed.items,
        isLoadMore: false,
        hasMore: feed.hasMore,
      );
      final savedVid =
          feed.lastVid ?? (feed.items.isEmpty ? null : feed.items.first.id);
      unawaited(
        _feedCache?.save(
          tabIndex,
          feed.items,
          hasMore: feed.hasMore,
          lastVid: savedVid,
        ),
      );
    } catch (_) {
      if (!ref.mounted ||
          generation != _generation ||
          state.tabIndex != tabIndex) {
        return;
      }
      // Stop automatic bottom-of-grid retry loops. Pull-to-refresh gives the
      // user an explicit retry path and resets this flag.
      feed.hasMore = false;
      state = state.copyWith(isLoadMore: false, hasMore: false);
    }
  }

  /// Records the card currently on screen so the next snapshot save can store
  /// the resume point. The page reports this as the user swipes.
  void noteCurrentVid(String vid) {
    if (vid.isEmpty) return;
    _feedFor(state.tabIndex).lastVid = vid;
  }

  Future<_FetchedFeed> _loadInitial(int tabIndex) async {
    final name = tabs[tabIndex];

    final kind = tabKinds[name]!;
    final tabType = tabTypes[name];
    if (tabType != null) {
      try {
        final page = await _homepageLoader(tabType: tabType);
        final items = _forceKind(page.items, kind);
        final nextOffset = page.nextOffset;
        final canAdvance = nextOffset != null && nextOffset > 0;
        if (items.isNotEmpty || canAdvance) {
          return _FetchedFeed(
            items: items,
            nextOffset: canAdvance ? nextOffset : null,
            sessionId: page.sessionId,
            searchPage: 0,
            recommendExhausted: !canAdvance,
            // Search remains available after recommendations are exhausted.
            hasMore: true,
          );
        }
      } catch (_) {
        // Older backends may not expose recommendations; search below keeps the
        // tab usable.
      }
    }

    final search = await _searchByType(name);
    final items = _searchItems(search, name, kind);
    final progress = _searchProgress(search, name, items, offset: 0);
    return _FetchedFeed(
      items: items,
      nextOffset: null,
      sessionId: null,
      searchPage: 1,
      searchOffsets: {
        if (progress.nextOffset != null) name: progress.nextOffset!,
      },
      searchCanAdvance: progress.hasCursor,
      recommendExhausted: true,
      hasMore: progress.hasMore,
    );
  }

  Future<_FetchedFeed> _loadNext(int tabIndex, _TabFeed feed) async {
    final name = tabs[tabIndex];

    final kind = tabKinds[name]!;
    final tabType = tabTypes[name];
    if (tabType != null && !feed.recommendExhausted) {
      try {
        final page = await _homepageLoader(
          tabType: tabType,
          offset: feed.offset,
          sessionId: feed.sessionId,
        );
        final items = _forceKind(page.items, kind);
        final nextOffset = page.nextOffset;
        final canAdvance = nextOffset != null && nextOffset > feed.offset;
        // Duplicate or empty pages can still lead to fresh recommendations.
        // Only an advancing cursor is safe to request again.
        if (canAdvance || items.any((item) => _isUnseen(feed, item))) {
          return _FetchedFeed(
            items: items,
            nextOffset: canAdvance ? nextOffset : null,
            sessionId: page.sessionId,
            searchPage: feed.searchPage,
            recommendExhausted: !canAdvance,
            hasMore: true,
          );
        }
      } catch (_) {
        // Fall through to search. A recommendation outage should not make the
        // whole category stop paginating.
      }
    }

    final pageNumber = feed.searchPage + 1;
    final searchOffset = feed.searchOffsets[name] ?? 0;
    final searchTabs = await _searchByType(
      name,
      page: pageNumber,
      offset: searchOffset,
    );
    final items = _searchItems(searchTabs, name, kind);
    final progress = _searchProgress(
      searchTabs,
      name,
      items,
      offset: searchOffset,
    );
    return _FetchedFeed(
      items: items,
      nextOffset: null,
      sessionId: feed.sessionId,
      searchPage: pageNumber,
      searchOffsets: {
        ...feed.searchOffsets,
        if (progress.nextOffset != null) name: progress.nextOffset!,
      },
      searchCanAdvance: progress.hasCursor,
      recommendExhausted: true,
      hasMore: progress.hasMore,
    );
  }

  void _applyFetched(
    _TabFeed feed,
    _FetchedFeed fetched, {
    required bool replace,
  }) {
    final fresh = <MediaItem>[];
    for (final item in fetched.items) {
      final key = '${item.kind}:${item.id}';
      if (item.id.isNotEmpty && feed.seen.add(key)) fresh.add(item);
    }
    feed
      ..items = replace ? fresh : [...feed.items, ...fresh]
      ..offset = fetched.nextOffset ?? feed.offset
      ..sessionId = fetched.sessionId ?? feed.sessionId
      ..searchPage = fetched.searchPage
      ..searchOffsets = fetched.searchOffsets
      ..recommendExhausted = fetched.recommendExhausted
      ..hasMore = fetched.hasMore
      ..loaded = true;

    // If a page contained only duplicates and no source has a known cursor,
    // stop cleanly instead of repeatedly requesting the same page.
    if (!replace &&
        fresh.isEmpty &&
        fetched.nextOffset == null &&
        !fetched.searchCanAdvance) {
      feed.hasMore = false;
    }
  }

  bool _isUnseen(_TabFeed feed, MediaItem item) =>
      item.id.isNotEmpty && !feed.seen.contains('${item.kind}:${item.id}');

  List<MediaItem> _searchItems(
    List<SearchTab> searchTabs,
    String label,
    String kind,
  ) {
    final matching = searchTabs.where(
      (tab) =>
          tab.title.isNotEmpty &&
          (tab.title.contains(label) || label.contains(tab.title)),
    );
    final selected = matching.isEmpty ? searchTabs : matching;
    return selected
        .expand((tab) => tab.items)
        .where((item) => item.kind == kind)
        .toList(growable: false);
  }

  ({bool hasMore, int? nextOffset, bool hasCursor}) _searchProgress(
    List<SearchTab> tabs,
    String label,
    List<MediaItem> items, {
    required int offset,
  }) => (
    hasMore:
        items.isNotEmpty &&
        !tabs.any(
          (tab) =>
              tab.hasMore == false &&
              tab.items.any((item) => item.kind == 'book'),
        ),
    nextOffset: null,
    hasCursor: false,
  );

  List<MediaItem> _forceKind(List<MediaItem> items, String kind) =>
      items.where((item) => item.kind == 'book').toList(growable: false);
}

final homeProvider = NotifierProvider<HomeNotifier, HomeState>(
  HomeNotifier.new,
);
