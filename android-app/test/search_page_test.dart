import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/search_page.dart';
import 'package:fqapp/services/search_history_store.dart';
import 'package:fqapp/widgets/media_card.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'rating-empty pages keep manual continuation at upstream cursors',
    (tester) async {
      final offsets = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: SearchPage(
            searchLoader:
                (query, {required int tabType, required int offset}) async {
                  offsets.add(offset);
                  return [
                    SearchTab(
                      title: '综合',
                      items: switch (offset) {
                        0 => [_item('low', '低分作品', score: 8.2)],
                        14 => [_item('unknown', '未评分作品')],
                        _ => [_item('high', '高分作品', score: 9.3)],
                      },
                      hasMore: offset < 27,
                      nextOffset: offset == 0 ? 14 : 27,
                    ),
                  ];
                },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('search-minimum-score')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('9 分及以上').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '评分');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(offsets, [0]);
      expect(find.byType(MediaCard), findsNothing);
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(offsets, [0, 14]);
      expect(find.byType(MediaCard), findsNothing);
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(offsets, [0, 14, 27]);
      expect(find.text('高分作品'), findsOneWidget);
      expect(find.text('9.3分'), findsOneWidget);
      expect(find.text('没有更多了'), findsOneWidget);
      await tester.tap(find.byKey(const Key('search-minimum-score')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('评分不限').last);
      await tester.pumpAndSettle();
      expect(_gridCount(tester), 3);
      expect(offsets, [0, 14, 27]);
    },
  );

  testWidgets('cover-free list reuses results and persists on reopening', (
    tester,
  ) async {
    var requests = 0;
    Future<List<SearchTab>> loader(
      String query, {
      required int tabType,
      required int offset,
    }) async {
      requests++;
      return [
        SearchTab(
          title: '综合',
          items: [_item('novel', '列表作品', score: 9.1)],
          hasMore: false,
        ),
      ];
    }

    await tester.pumpWidget(_app(loader));
    await tester.pumpAndSettle();
    expect(find.byType(MediaCard), findsOneWidget);
    await tester.tap(find.byKey(const Key('search-layout-toggle')));
    await tester.pumpAndSettle();
    expect(find.byType(MediaCard), findsNothing);
    expect(find.text('列表作品'), findsOneWidget);
    expect(find.text('小说 · 9.1分'), findsOneWidget);
    expect(requests, 1);
    expect(
      (await SharedPreferences.getInstance()).getBool('search_list_view'),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_app(loader));
    await tester.pumpAndSettle();
    expect(find.byType(MediaCard), findsNothing);
    expect(find.text('列表作品'), findsOneWidget);
    expect(find.byTooltip('切换为封面视图'), findsOneWidget);
  });

  testWidgets('the rating threshold survives reopening the page', (
    tester,
  ) async {
    Future<List<SearchTab>> loader(
      String query, {
      required int tabType,
      required int offset,
    }) async => [
      SearchTab(
        title: '综合',
        items: [_item('low', '低分作品', score: 8.2)],
        hasMore: false,
      ),
    ];

    await tester.pumpWidget(_app(loader));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('search-minimum-score')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('9 分及以上').last);
    await tester.pumpAndSettle();
    expect(
      (await SharedPreferences.getInstance()).getDouble('search_minimum_score'),
      9,
    );

    // Reopening is the reported symptom: the dropdown used to snap back to
    // 「评分不限」 and the filter the viewer picked was silently dropped.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_app(loader));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DropdownButton<double>>(
            find.byKey(const Key('search-minimum-score')),
          )
          .value,
      9,
    );
    await tester.enterText(find.byType(TextField), '评分');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    // 8.2 is below the restored 9-point threshold, so it stays filtered out.
    expect(find.byType(MediaCard), findsNothing);
  });

  testWidgets('list and grid captions show the work length', (tester) async {
    await tester.pumpWidget(
      _app(
        (query, {required int tabType, required int offset}) async => [
          SearchTab(
            title: '综合',
            items: [
              _item('novel', '长篇小说', wordNumber: 2000000, score: 9.1),
              _item('drama', '短剧作品', kind: 'video', ep: '103'),
            ],
            hasMore: false,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('200万字'), findsWidgets);
    expect(find.textContaining('共103集'), findsNothing);

    await tester.tap(find.byKey(const Key('search-layout-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('小说 · 200万字 · 9.1分'), findsOneWidget);
    expect(find.text('短剧 · 共103集 · 暂无评分'), findsNothing);
  });

  testWidgets('an empty first page can continue at the actual cursor 14', (
    tester,
  ) async {
    final offsets = <int>[];
    await tester.pumpWidget(
      _app((query, {required int tabType, required int offset}) async {
        offsets.add(offset);
        return [
          SearchTab(
            title: '综合',
            items: offset == 14 ? [_item('book', '后续小说')] : [],
            hasMore: offset == 0,
            nextOffset: offset == 0 ? 14 : 0,
          ),
        ];
      }),
    );
    await tester.pumpAndSettle();
    expect(offsets, [0]);
    expect(find.text('加载更多'), findsOneWidget);
    expect(find.text('没有更多了'), findsNothing);
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(offsets, [0, 14]);
    expect(find.text('后续小说'), findsOneWidget);
    expect(find.text('没有更多了'), findsOneWidget);
  });

  testWidgets(
    'duplicate pages preserve their advancing cursor without looping',
    (tester) async {
      final offsets = <int>[];
      await tester.pumpWidget(
        _app((query, {required int tabType, required int offset}) async {
          offsets.add(offset);
          return [
            SearchTab(
              title: '综合',
              items: [
                _item('one', '第一本'),
                if (offset == 27) _item('two', '第二本'),
              ],
              hasMore: offset != 27,
              nextOffset: offset == 0 ? 14 : (offset == 14 ? 27 : 0),
            ),
          ];
        }),
      );
      await tester.pumpAndSettle();
      expect(offsets, [
        0,
        14,
      ], reason: 'No automatic loop through duplicate pages');
      expect(find.text('加载更多'), findsOneWidget);
      expect(find.text('没有更多了'), findsNothing);
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(offsets, [0, 14, 27]);
      expect(find.text('第一本'), findsOneWidget);
      expect(find.text('第二本'), findsOneWidget);
      expect(_gridCount(tester), 2);
    },
  );

  for (final terminal in <({String label, bool? hasMore, int? next})>[
    (label: 'explicit exhaustion', hasMore: false, next: 28),
    (label: 'unchanged cursor', hasMore: true, next: 14),
    (label: 'backward cursor', hasMore: true, next: 7),
    (label: 'missing cursor', hasMore: true, next: null),
  ]) {
    testWidgets('pagination stops on ${terminal.label}', (tester) async {
      final offsets = <int>[];
      await tester.pumpWidget(
        _app((query, {required int tabType, required int offset}) async {
          offsets.add(offset);
          return [
            SearchTab(
              title: '综合',
              items: [_item('one', '唯一作品')],
              hasMore: offset == 0 ? true : terminal.hasMore,
              nextOffset: offset == 0 ? 14 : terminal.next,
            ),
          ];
        }),
      );
      await tester.pumpAndSettle();
      expect(offsets, [0, 14]);
      expect(find.text('没有更多了'), findsOneWidget);
      expect(find.text('加载更多'), findsNothing);
    });
  }

  testWidgets('a valid cursor can advance when has_more is omitted', (
    tester,
  ) async {
    final offsets = <int>[];
    await tester.pumpWidget(
      _app((query, {required int tabType, required int offset}) async {
        offsets.add(offset);
        return [
          SearchTab(
            title: '综合',
            items: offset == 0 ? [] : [_item('one', '后续作品')],
            nextOffset: offset == 0 ? 14 : null,
          ),
        ];
      }),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(offsets, [0, 14]);
    expect(find.text('后续作品'), findsOneWidget);
  });



  testWidgets('pagination failures retain results and retry the same cursor', (
    tester,
  ) async {
    final offsets = <int>[];
    var failed = false;
    await tester.pumpWidget(
      _app((query, {required int tabType, required int offset}) async {
        offsets.add(offset);
        if (offset == 14 && !failed) {
          failed = true;
          throw Exception('分页失败');
        }
        return [
          SearchTab(
            title: '综合',
            items: [_item('$offset', '作品 $offset')],
            hasMore: offset == 0,
            nextOffset: offset == 0 ? 14 : 0,
          ),
        ];
      }),
    );
    await tester.pumpAndSettle();
    expect(offsets, [0, 14]);
    expect(find.text('作品 0'), findsOneWidget);
    expect(find.text('加载失败，点击重试'), findsOneWidget);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -100));
    await tester.pumpAndSettle();
    expect(offsets, [0, 14], reason: 'Scrolling must not retry a failed page');
    await tester.tap(find.text('加载失败，点击重试'));
    await tester.pumpAndSettle();
    expect(offsets, [0, 14, 14]);
    expect(find.text('作品 14'), findsOneWidget);
    expect(_gridCount(tester), 2);
  });

  for (final failLate in [false, true]) {
    testWidgets(
      'a new query ignores a late page ${failLate ? 'error' : 'result'}',
      (tester) async {
        final oldPage = Completer<List<SearchTab>>();
        final requests = <(String, int, int)>[];
        await tester.pumpWidget(
          _app((query, {required int tabType, required int offset}) async {
            requests.add((query, tabType, offset));
            if (query == '测试' && offset == 14) return oldPage.future;
            return [
              SearchTab(
                title: '综合',
                items: [_item(query, '$query 作品')],
                hasMore: query == '测试',
                nextOffset: query == '测试' ? 14 : 0,
              ),
            ];
          }),
        );
        await tester.pump();
        await tester.pump();
        expect(requests, [('测试', 3, 0), ('测试', 3, 14)]);
        await tester.enterText(find.byType(TextField), '新关键词');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        if (failLate) {
          oldPage.completeError(Exception('过期请求失败'));
        } else {
          oldPage.complete([
            SearchTab(
              title: '综合',
              items: [_item('stale', '过期作品')],
              hasMore: true,
              nextOffset: 27,
            ),
          ]);
        }
        await tester.pumpAndSettle();
        expect(find.text('新关键词 作品'), findsOneWidget);
        expect(find.text('过期作品'), findsNothing);
        expect(find.text('加载失败，点击重试'), findsNothing);
        expect(requests.last, ('新关键词', 3, 0));
        expect(requests, hasLength(3));
      },
    );
  }

  testWidgets('clearing input and disposing ignore pending responses', (
    tester,
  ) async {
    final pending = <Completer<List<SearchTab>>>[];
    await tester.pumpWidget(
      _app((query, {required int tabType, required int offset}) {
        final result = Completer<List<SearchTab>>();
        pending.add(result);
        return result.future;
      }),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('清空'));
    await tester.pumpAndSettle();
    pending.first.complete([
      SearchTab(title: '综合', items: [_item('stale', '过期作品')]),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('搜索历史'), findsOneWidget);
    expect(find.byType(ChoiceChip), findsOneWidget);
    await tester.tap(find.text('测试'));
    await tester.pump();
    expect(pending, hasLength(2));
    await tester.pumpWidget(const SizedBox());
    pending.last.completeError(Exception('页面已关闭'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('history can search again, delete one entry and clear all', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'search_history_v1': ['小王子', '测试小说'],
    });
    final queries = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: SearchPage(
          searchLoader:
              (query, {required int tabType, required int offset}) async {
                queries.add(query);
                return [];
              },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('小王子'));
    await tester.pumpAndSettle();
    expect(queries, ['小王子']);
    await tester.tap(find.byTooltip('清空'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('删除 小王子'));
    await tester.pumpAndSettle();
    expect(find.text('小王子'), findsNothing);
    expect(find.text('测试小说'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '清空'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '清空').last);
    await tester.pumpAndSettle();
    expect(find.text('暂无搜索历史'), findsOneWidget);
    expect(await SearchHistoryStore.instance.load(), isEmpty);
  });

  testWidgets('late initial history cannot replace a newly searched keyword', (
    tester,
  ) async {
    final history = _DelayedHistory();
    await tester.pumpWidget(
      MaterialApp(
        home: SearchPage(
          initialQuery: '新搜索',
          historyStore: history,
          searchLoader:
              (query, {required int tabType, required int offset}) async => [],
        ),
      ),
    );
    await tester.pumpAndSettle();
    history.initial.complete(['旧搜索']);
    await tester.pump();
    await tester.tap(find.byTooltip('清空'));
    await tester.pumpAndSettle();
    expect(find.text('新搜索'), findsOneWidget);
    expect(find.text('旧搜索'), findsNothing);
  });

  testWidgets('loads and deduplicates the next search page near the bottom', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final offsets = <int>[];
    await tester.pumpWidget(
      _app((query, {required int tabType, required int offset}) async {
        offsets.add(offset);
        return [
          SearchTab(
            title: '综合',
            items: offset == 0
                ? [for (var i = 1; i <= 30; i++) _item('$i', '第$i本')]
                : [_item('30', '重复条目'), _item('31', '第31本')],
            hasMore: offset == 0,
            nextOffset: offset == 0 ? 14 : 0,
          ),
        ];
      }),
    );
    await tester.pumpAndSettle();
    expect(offsets, [0]);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -3000));
    await tester.pumpAndSettle();

    expect(offsets, [0, 14]);
    expect(_gridCount(tester), 31);
    expect(find.text('第31本'), findsOneWidget);
    expect(find.text('重复条目'), findsNothing);
  });
}

Widget _app(SearchPageLoader loader) => MaterialApp(
  home: SearchPage(
    initialQuery: '测试',
    searchLoader: loader,
    historyStore: _DelayedHistory()..initial.complete([]),
  ),
);

int _gridCount(WidgetTester tester) {
  final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
  return (grid.delegate as SliverChildBuilderDelegate).childCount!;
}

MediaItem _item(
  String id,
  String title, {
  String kind = 'book',
  double? score,
  String ep = '',
  int wordNumber = 0,
}) => MediaItem(
  id: id,
  title: title,
  cover: '',
  author: '',
  badge: '',
  ep: ep,
  kind: kind,
  wordNumber: wordNumber,
  score: score,
);

class _DelayedHistory implements SearchHistoryRepository {
  final initial = Completer<List<String>>();
  List<String> items = [];
  @override
  Future<List<String>> load() => initial.future;
  @override
  Future<List<String>> add(String query) async =>
      items = mergeSearchHistory(items, query);
  @override
  Future<List<String>> remove(String query) async =>
      items = items.where((value) => value != query).toList();
  @override
  Future<void> clear() async => items = [];
}
