import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/pages/imported_book_reader.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/imported_book_store.dart';
import 'support/fakes.dart';

void main() {
  testWidgets('local resume opens disk text at the saved chapter', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    late Directory root;
    late ImportedBookStore store;
    late ImportedBook book;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('fqapp-local-resume-');
      store = ImportedBookStore(rootDirectoryProvider: () async => root);
      book = await store.importBytes(
        fileName: 'resume.txt',
        bytes: Uint8List.fromList(
          utf8.encode('第一章 开始\n这是第一章正文。\n第二章 继续\n这是第二章正文。'),
        ),
      );
    });
    expect(book.chapters.length, 2);
    final history = MemoryReaderStore(
      entry: {
        'id': book.id,
        'kind': 'book',
        'chapterId': book.chapters[1].itemId,
        'episode': 0,
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => openImportedBook(
                context,
                book.toMediaItem(),
                source: store,
                readerStore: history,
              ),
              child: const Text('resume'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('resume'));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
      if (find.byType(ReaderPage).evaluate().isNotEmpty) break;
    }
    final reader = tester.widget<ReaderPage>(find.byType(ReaderPage));
    expect(reader.localOnly, isTrue);
    expect(reader.startIndex, 1);
    expect(
      await tester.runAsync(() => reader.chapterLoader!(book.chapters[1])),
      contains('这是第二章正文'),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(() => root.delete(recursive: true));
  });
}
