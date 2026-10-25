import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/library_store.dart';

class MemoryReaderStore implements ReaderStore {
  Map<String, dynamic>? entry;
  double seconds = 0;
  MemoryReaderStore({this.entry});

  @override
  Future<Map<String, dynamic>?> historyEntry(String id) async => entry;

  @override
  Future<void> addHistory(Map<String, dynamic> value) async =>
      entry = Map<String, dynamic>.from(value);

  @override
  Future<void> updateProgress(
    String id,
    int episode,
    double progress, {
    String? chapterId,
    double? position,
    double? maxScroll,
  }) async {
    entry = {
      ...?entry,
      'id': id,
      'episode': episode,
      'progress': progress,
      'chapterId': ?chapterId,
      'position': ?position,
      'maxScroll': ?maxScroll,
    };
  }

  @override
  Future<void> accumulateReadTime(
    String bookId,
    String kind,
    double seconds, {
    DateTime? at,
  }) async => this.seconds += seconds;

  /// 已看集（按剧集/视频 id）。
  final Map<String, Set<String>> watched = {};

  @override
  Future<Set<String>> watchedEpisodeIds(String id) async =>
      watched[id]?.toSet() ?? <String>{};

  @override
  Future<void> markEpisodeWatched(
    String id,
    Iterable<String> episodeIds,
  ) async {
    (watched[id] ??= <String>{}).addAll(episodeIds);
  }

  @override
  Future<void> forgetWatchedEpisodes(String id) async => watched.remove(id);
}

class MemoryChapterCache implements ChapterCache {
  MemoryChapterCache({this.chapterCapacity = 500});

  final Map<String, Map<String, String>> content = {};
  final Map<String, CachedBook> catalogs = {};

  /// Chapter ids written with `pinned: true`, per book: what a real store keeps
  /// outside its automatic-cache budget.
  final Map<String, Set<String>> pinned = {};

  @override
  final int chapterCapacity;

  @override
  Future<String?> read({
    required String bookId,
    required String chapterId,
  }) async => content[bookId]?[chapterId];

  @override
  Future<void> write({
    required String bookId,
    required String chapterId,
    required String title,
    required String text,
    bool pinned = false,
  }) async {
    (content[bookId] ??= {})[chapterId] = text;
    if (pinned) (this.pinned[bookId] ??= <String>{}).add(chapterId);
  }

  @override
  Future<void> saveBook(CachedBook book) async => catalogs[book.id] = book;

  @override
  Future<Set<String>> cachedChapterIds(String bookId) async =>
      content[bookId]?.keys.toSet() ?? {};

  @override
  Future<CachedBook?> cachedBook(String bookId) async {
    final chapters = content[bookId];
    if (chapters == null || chapters.isEmpty) return null;
    // 目录没存过时按缓存章节重建，与真实 store 的兜底规则一致。
    return catalogs[bookId] ??
        CachedBook(
          id: bookId,
          title: bookId,
          chapters: [
            for (final id in chapters.keys)
              Chapter(itemId: id, title: '', volumeName: ''),
          ],
        );
  }
}
