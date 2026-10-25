import 'package:flutter/material.dart';
import '../models/media_item.dart';
import '../services/imported_book_store.dart';
import '../services/library_store.dart';
import '../services/reader_history.dart';
import 'reader_page.dart';

/// All local-book entry points use disk chapters and the same saved progress.
Future<void> openImportedBook(
  BuildContext context,
  MediaItem item, {
  ImportedBookStore? source,
  ReaderStore? readerStore,
}) async {
  final store = source ?? ImportedBookStore.instance;
  final book = await store.book(item.id);
  if (!context.mounted) return;
  if (book == null || book.chapters.isEmpty) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('本地书籍文件不可用')));
    return;
  }
  final history = readerStore ?? LibraryStore.instance;
  Map<String, dynamic>? saved;
  try {
    saved = await ReaderHistory(history).load(book.id);
  } catch (_) {}
  if (!context.mounted) return;
  var startIndex = book.chapters.indexWhere(
    (chapter) => chapter.itemId == saved?['chapterId']?.toString(),
  );
  if (startIndex < 0) {
    final episode = num.tryParse(saved?['episode']?.toString() ?? '');
    startIndex = episode != null && episode.isFinite
        ? episode.toInt().clamp(0, book.chapters.length - 1).toInt()
        : 0;
  }
  await Navigator.push<void>(
    context,
    MaterialPageRoute<void>(
      builder: (_) => ReaderPage(
        bookId: book.id,
        title: book.title,
        chapters: book.chapters,
        startIndex: startIndex,
        localOnly: true,
        readerStore: history,
        chapterLoader: (chapter) => store.chapterText(book.id, chapter.itemId),
      ),
    ),
  );
}
