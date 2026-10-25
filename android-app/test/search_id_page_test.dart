import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/search_page.dart';
import 'package:fqapp/services/search_history_store.dart';
import 'package:fqapp/widgets/media_card.dart';

const _id = '7677801492920667198';

void main() {
  testWidgets(
    'explicit ID prefix supports short IDs and bare 1984 stays a title',
    (tester) async {
      final ids = <String>[];
      final keywords = <String>[];
      await tester.pumpWidget(
        _app(
          initialQuery: 'ID: 1984',
          idLoader: (id) async {
            ids.add(id);
            return _item(id, 'ID 对应作品', 'book');
          },
          keywordLoader:
              (query, {required int tabType, required int offset}) async {
                keywords.add(query);
                return [
                  SearchTab(
                    title: '综合',
                    items: [_item('other', '数字书名', 'book')],
                    hasMore: false,
                  ),
                ];
              },
        ),
      );
      await tester.pumpAndSettle();
      expect(ids, ['1984']);
      expect(keywords, isEmpty);
      await tester.enterText(find.byType(TextField), '1984');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(keywords, ['1984']);
      expect(ids, ['1984']);
      expect(find.text('数字书名'), findsOneWidget);
      expect(find.text('按作品 ID 查找'), findsNothing);
    },
  );

  testWidgets(
    'missing IDs show no fabricated result and allow keyword search',
    (tester) async {
      final keywords = <String>[];
      await tester.pumpWidget(
        _app(
          idLoader: (_) async => null,
          keywordLoader:
              (query, {required int tabType, required int offset}) async {
                keywords.add(query);
                return [
                  SearchTab(
                    title: '综合',
                    items: [_item('book', '关键词命中', 'book')],
                    hasMore: false,
                  ),
                ];
              },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('未找到该 ID 对应的作品'), findsOneWidget);
      expect(find.byType(MediaCard), findsNothing);
      expect(keywords, isEmpty);
      await tester.tap(find.text('按关键词搜索'));
      await tester.pumpAndSettle();
      expect(keywords, [_id]);
      expect(find.text('关键词命中'), findsOneWidget);
      expect(find.text('按作品 ID 查找'), findsNothing);
    },
  );

  testWidgets('a late keyword response cannot overwrite a new ID lookup', (
    tester,
  ) async {
    final pending = Completer<List<SearchTab>>();
    await tester.pumpWidget(
      _app(
        initialQuery: '旧关键词',
        idLoader: (id) async => _item(id, 'ID 结果', 'book'),
        keywordLoader: (query, {required int tabType, required int offset}) =>
            pending.future,
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), _id);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    pending.complete([
      SearchTab(title: '综合', items: [_item('old', '旧关键词结果', 'book')]),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('ID 结果'), findsOneWidget);
    expect(find.text('旧关键词结果'), findsNothing);
  });

  testWidgets(
    'clearing and closing the page ignore pending ID results and errors',
    (tester) async {
      final pending = <Completer<MediaItem?>>[];
      await tester.pumpWidget(
        _app(
          idLoader: (_) {
            final request = Completer<MediaItem?>();
            pending.add(request);
            return request.future;
          },
        ),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('清空'));
      await tester.pumpAndSettle();
      pending.first.complete(_item(_id, '过期 ID 结果', 'manju'));
      await tester.pumpAndSettle();
      expect(find.text('搜索历史'), findsOneWidget);
      expect(find.text('过期 ID 结果'), findsNothing);
      await tester.tap(find.text(_id));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      pending.last.completeError(Exception('页面已关闭'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}

Widget _app({
  String initialQuery = _id,
  required Future<MediaItem?> Function(String) idLoader,
  SearchPageLoader? keywordLoader,
}) => MaterialApp(
  home: SearchPage(
    initialQuery: initialQuery,
    idSearchLoader: idLoader,
    searchLoader:
        keywordLoader ??
        (query, {required int tabType, required int offset}) async => [],
    historyStore: _History(),
  ),
);

MediaItem _item(String id, String title, String kind) => MediaItem(
  id: id,
  title: title,
  kind: kind,
  cover: '',
  author: '',
  badge: '',
  ep: '',
  seriesId: kind == 'manju' ? id : null,
);

class _History implements SearchHistoryRepository {
  List<String> items = [];
  @override
  Future<List<String>> load() async => items;
  @override
  Future<List<String>> add(String query) async =>
      items = mergeSearchHistory(items, query);
  @override
  Future<List<String>> remove(String query) async =>
      items = items.where((item) => item != query).toList();
  @override
  Future<void> clear() async => items = [];
}
