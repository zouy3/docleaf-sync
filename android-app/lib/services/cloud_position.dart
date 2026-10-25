import '../widgets/reader/reader_chapter_layout.dart';

String canonicalReadingText(String text) =>
    text.replaceAll(RegExp(r'[\s\u200b\ufeff]+'), '');

Map<String, dynamic>? captureCloudPosition(
  List<ReaderContentBlock> all,
  int textOffset,
  String chapterId,
  int chapterIndex,
  String title,
) {
  final blocks = all.where((b) => !b.isTitle && !b.isImage).toList();
  if (blocks.isEmpty) return null;
  final block = blocks.lastWhere(
    (b) => b.start <= textOffset,
    orElse: () => blocks.first,
  );
  final offset = canonicalReadingText(
    block.text.substring(
      0,
      (textOffset - block.start).clamp(0, block.text.length),
    ),
  ).length;
  final normalized = canonicalReadingText(block.text);
  var quoteStart = offset;
  if (quoteStart > 0 &&
      quoteStart < normalized.length &&
      normalized.codeUnitAt(quoteStart) >= 0xdc00 &&
      normalized.codeUnitAt(quoteStart) <= 0xdfff) {
    quoteStart--;
  }
  var quoteEnd = (quoteStart + 32).clamp(0, normalized.length);
  if (quoteEnd > quoteStart &&
      normalized.codeUnitAt(quoteEnd - 1) >= 0xd800 &&
      normalized.codeUnitAt(quoteEnd - 1) <= 0xdbff) {
    quoteEnd--;
  }
  return {
    'version': 1,
    'chapter_id': chapterId,
    'chapter_index': chapterIndex,
    'chapter_title': title,
    'paragraph_id': block.paraIndex?.toString(),
    'ordinal': blocks.indexOf(block),
    'character_offset': offset,
    'quote': normalized.substring(quoteStart, quoteEnd),
  };
}

int? resolveCloudPosition(
  List<ReaderContentBlock> all,
  Map<String, dynamic> cursor,
) {
  final blocks = all.where((b) => !b.isTitle && !b.isImage).toList();
  if (blocks.isEmpty) return null;
  final id = cursor['paragraph_id']?.toString();
  final quote = cursor['quote'] as String? ?? '';
  ReaderContentBlock? selected;
  for (final b in blocks) {
    if (id != null && b.paraIndex?.toString() == id) {
      selected = b;
      break;
    }
  }
  if (selected == null && quote.isNotEmpty) {
    for (final b in blocks) {
      if (canonicalReadingText(b.text).contains(quote)) {
        selected = b;
        break;
      }
    }
  }
  final ordinal = (cursor['ordinal'] as num?)?.toInt() ?? 0;
  selected ??= blocks[ordinal.clamp(0, blocks.length - 1)];
  final normalized = canonicalReadingText(selected.text);
  final found = quote.isEmpty ? -1 : normalized.indexOf(quote);
  final desired = found >= 0
      ? found
      : ((cursor['character_offset'] as num?)?.toInt() ?? 0).clamp(
          0,
          normalized.length,
        );
  var offset = 0, count = 0;
  while (offset < selected.text.length && count < desired) {
    if (canonicalReadingText(selected.text[offset]).isNotEmpty) count++;
    offset++;
  }
  return selected.start + offset;
}
