import '../models/media_item.dart';
import 'library_store.dart';

/// Keeps resume reads behind pending saves from earlier reader page instances.
class ReaderHistory {
  static final _writes = Expando<Future<void>>('reader history writes');
  final ReaderStore store;

  ReaderHistory(this.store);

  Future<Map<String, dynamic>?> load(String bookId) async {
    await _writes[store];
    return store.historyEntry(bookId);
  }

  Future<void> save(Map<String, dynamic> entry, {bool createHistory = false}) {
    final guard = ReadingDataWriteGuard(store);
    final snapshot = Map<String, dynamic>.from(entry);
    final previous = _writes[store] ?? Future<void>.value();
    final write = previous.then((_) async {
      if (!guard.canWriteHistory) return;
      try {
        // Every caller already supplies the full snapshot. Retrying it also
        // retries a failed first insert; a partial update could otherwise
        // overwrite a legacy record belonging to another media kind.
        await store.addHistory(snapshot);
      } catch (_) {
        // Storage errors must not interrupt reading or poison later saves.
      }
    });
    _writes[store] = write;
    return write.whenComplete(() {
      if (identical(_writes[store], write)) _writes[store] = null;
    });
  }
}

/// Prefer stable chapter identity over an obsolete saved index.
int? resumeChapterIndex(Map<String, dynamic>? saved, List<Chapter> episodes) {
  final id = saved?['episodeId'] ?? saved?['chapterId'];
  if (id is String && id.isNotEmpty) {
    final index = episodes.indexWhere((episode) => episode.itemId == id);
    return index < 0 ? null : index;
  }
  final index = saved?['episode'];
  if (index is! num ||
      !index.isFinite ||
      index != index.truncateToDouble() ||
      index < 0 ||
      index >= episodes.length) {
    return null;
  }
  return index.toInt();
}
