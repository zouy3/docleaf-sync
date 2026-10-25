import 'dart:io';
import 'package:hive_ce/hive.dart';
import 'package:fqapp/pages/library_page.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/main.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/rank.dart';
import 'package:fqapp/pages/home_page.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/pages/search_page.dart';
import 'package:fqapp/pages/settings_page.dart';
import 'package:fqapp/pages/rank_page.dart';
import 'package:fqapp/services/api_client.dart';

MediaItem item(String kind) => MediaItem(
  id: kind,
  title: '$kind-result',
  cover: '',
  author: '',
  badge: '',
  ep: '',
  kind: kind,
);
HomeNotifier feed() => HomeNotifier(
  searchLoader: (query, {int page = 1}) async => [
    SearchTab(title: '书籍', items: [], hasMore: false),
  ],
  homepageLoader: ({int tabType = 2, int offset = 0, String? sessionId}) async {
    expect(tabType, 2);
    return HomepagePage(
      items: [item('book'), item('video'), item('manga')],
      nextOffset: null,
      sessionId: null,
    );
  },
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('external input configuration changes are handled by the activity', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final changes = RegExp(
      r'android:configChanges="([^"]+)"',
    ).firstMatch(manifest)!.group(1)!.split('|');
    expect(
      changes,
      containsAll(['keyboard', 'keyboardHidden', 'navigation', 'touchscreen']),
    );
  });
  testWidgets('home requests novels and excludes non-novel feed results', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [homeProvider.overrideWith(feed)],
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('book-result'), findsWidgets);
    expect(find.text('video-result'), findsNothing);
    expect(find.text('manga-result'), findsNothing);
    expect(find.text('短剧'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('shell has three reading destinations', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [homeProvider.overrideWith(feed)],
        child: MaterialApp(home: RootShell(backendStarter: () async {})),
      ),
    );
    await tester.pumpAndSettle();
    final destinations = tester
        .widget<NavigationBar>(find.byType(NavigationBar))
        .destinations;
    expect(
      destinations.whereType<NavigationDestination>().map((d) => d.label),
      ['首页', '书架', '我的'],
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('search only requests and displays novel results', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SearchPage(
          initialQuery: '小说',
          searchLoader: (query, {required tabType, required offset}) async {
            expect(tabType, 3);
            return [
              SearchTab(
                title: '书籍',
                items: [item('book'), item('video')],
                hasMore: false,
              ),
            ];
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('book-result'), findsOneWidget);
    expect(find.text('video-result'), findsNothing);
    expect(find.widgetWithText(ChoiceChip, '短剧'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('settings excludes media playback and drama cache', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pumpAndSettle();
    expect(find.text('阅读'), findsOneWidget);
    expect(find.text('短剧'), findsNothing);
    expect(find.text('听书'), findsNothing);
    expect(find.text('剧集离线缓存'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('rank catalogue excludes drama and manga boards', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RankPage(
          catalogLoader: () async => const RankCatalog(
            rankId: 'novel-rank',
            tabs: [
              RankTab(name: '小说榜', algo: 1),
              RankTab(name: '短剧榜', algo: 2),
              RankTab(name: '漫画榜', algo: 3),
            ],
          ),
          pageLoader:
              ({
                required rankId,
                required algo,
                required categoryId,
                required offset,
                required startAt,
              }) async {
                expect(algo, 1);
                return RankBoard.empty;
              },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('小说榜'), findsOneWidget);
    expect(find.text('短剧榜'), findsNothing);
    expect(find.text('漫画榜'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('novel shelf hides legacy media without deleting its records', (
    tester,
  ) async {
    late Directory directory;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('fqapp-novel-shelf-');
      Hive.init(directory.path);
      await LibraryStore.instance.init();
      await ShelfStore.instance.init();
      for (final kind in ['book', 'video']) {
        await LibraryStore.instance.addHistory({
          'id': kind,
          'title': '$kind-result',
          'kind': kind,
        });
        await ShelfStore.instance.toggle(item(kind));
      }
    });
    try {
      await tester.pumpWidget(const MaterialApp(home: LibraryPage()));
      await tester.pumpAndSettle();
      expect(find.text('book-result'), findsWidgets);
      expect(find.text('video-result'), findsNothing);
      expect(LibraryStore.instance.historySnapshot().length, 2);
      expect(ShelfStore.instance.records().length, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      await tester.runAsync(() async {
        await Hive.close();
        await directory.delete(recursive: true);
      });
    }
  });
}
