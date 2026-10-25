import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';

MediaItem book(String id, {String kind = 'book'}) => MediaItem(
  id: id,
  title: id,
  cover: '',
  author: '',
  badge: '',
  ep: '',
  kind: kind,
);
HomepagePage page(List<MediaItem> items, {int? next}) =>
    HomepagePage(items: items, nextOffset: next, sessionId: 'novel-session');
void main() {
  test(
    'novel pagination preserves cursor, deduplicates, and excludes media',
    () async {
      final offsets = <int>[];
      final provider = NotifierProvider<HomeNotifier, HomeState>(
        () => HomeNotifier(
          homepageLoader:
              ({int tabType = 2, int offset = 0, String? sessionId}) async {
                expect(tabType, 2);
                offsets.add(offset);
                if (offset == 0) {
                  return page([
                    book('a'),
                    book('video', kind: 'video'),
                  ], next: 10);
                }
                expect(sessionId, 'novel-session');
                return page([book('a'), book('b')]);
              },
          searchLoader: (_, {int page = 1}) async => [],
        ),
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(provider.notifier);
      await notifier.load();
      await notifier.loadMore();
      expect(offsets, [0, 10]);
      expect(container.read(provider).items.map((x) => x.id), ['a', 'b']);
    },
  );
  test('late refresh cannot overwrite the newer novel response', () async {
    final first = Completer<HomepagePage>();
    var calls = 0;
    final provider = NotifierProvider<HomeNotifier, HomeState>(
      () => HomeNotifier(
        homepageLoader:
            ({int tabType = 2, int offset = 0, String? sessionId}) =>
                ++calls == 1 ? first.future : Future.value(page([book('new')])),
        searchLoader: (_, {int page = 1}) async => [],
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(provider.notifier);
    final oldLoad = notifier.load();
    await notifier.load(manualRefresh: true);
    first.complete(page([book('stale')]));
    await oldLoad;
    expect(container.read(provider).items.single.id, 'new');
  });
  test('recommendation outage falls back to novel search only', () async {
    final queries = <String>[];
    final provider = NotifierProvider<HomeNotifier, HomeState>(
      () => HomeNotifier(
        homepageLoader:
            ({int tabType = 2, int offset = 0, String? sessionId}) async =>
                throw StateError('offline'),
        searchLoader: (query, {int page = 1}) async {
          queries.add(query);
          return [
            SearchTab(title: '书籍', items: [book('novel')], hasMore: false),
          ];
        },
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(provider.notifier).load();
    expect(queries, ['小说']);
    expect(container.read(provider).items.single.id, 'novel');
    expect(container.read(provider).hasMore, isFalse);
  });
}
