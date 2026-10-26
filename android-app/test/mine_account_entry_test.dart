import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/pages/mine_page.dart';
import 'package:fqapp/pages/cloud_sync_page.dart';
import 'package:fqapp/services/cloud_sync.dart';
import 'package:fqapp/services/library_store.dart';

void main() {
  late Directory temp;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('docleaf-account-entry-test-');
    Hive.init(temp.path);
    await LibraryStore.instance.init();
  });
  tearDown(() async {
    await Hive.close();
    await temp.delete(recursive: true);
  });
  testWidgets(
    'prominent account card opens login and shows signed-in account',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 900));
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.binding.setSurfaceSize(null);
      });
      await tester.pumpWidget(const MaterialApp(home: MinePage()));
      await tester.pumpAndSettle();
      expect(find.text('登录并同步'), findsOneWidget);
      await tester.tap(find.text('登录并同步'));
      await tester.pumpAndSettle();
      expect(find.byType(CloudSyncPage), findsOneWidget);
      expect(find.text('用户名'), findsOneWidget);
      Navigator.of(tester.element(find.byType(CloudSyncPage))).pop();
      await tester.pumpAndSettle();
      CloudSync.instance.session = {
        'user': {
          'id': 'test',
          'user_metadata': {'username': 'reader_test'},
        },
      };
      CloudSync.instance.status = '同步完成';
      await tester.pumpWidget(
        const MaterialApp(home: MinePage(key: ValueKey('signed-in'))),
      );
      await tester.pumpAndSettle();
      expect(find.text('reader_test'), findsOneWidget);
      expect(find.text('同步完成'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      CloudSync.instance.dispose();
    },
  );
}
