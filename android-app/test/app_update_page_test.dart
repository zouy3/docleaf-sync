import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/pages/app_update_page.dart';
import 'package:fqapp/services/app_update.dart';

void main() {
  testWidgets(
    'saved update channel is visible and can change without resetting settings',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'docleaf_update_preview': false,
        'reader_font_size': 26,
      });
      final service = AppUpdateService(
        client: MockClient((_) async => http.Response('[]', 200)),
        deviceLoader: () async => const UpdateDevice(
          'com.fqapp.fqapp',
          137,
          '1.0.132',
          ['arm64-v8a'],
        ),
        directory: () async => Directory.systemTemp,
      );
      await tester.pumpWidget(
        MaterialApp(home: AppUpdatePage(service: service)),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DropdownButtonFormField<UpdateChannel>>(
              find.byType(DropdownButtonFormField<UpdateChannel>),
            )
            .initialValue,
        UpdateChannel.stable,
      );
      await tester.tap(find.byType(DropdownButtonFormField<UpdateChannel>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('试用版（含正式版）').last);
      await tester.runAsync(() async {
        await (() async {
          while (service.busy) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        })().timeout(const Duration(seconds: 2));
      });
      await tester.pumpAndSettle();
      expect(service.channel, UpdateChannel.preview);
      expect(
        (await SharedPreferences.getInstance()).getInt('reader_font_size'),
        26,
      );
      expect(
        find.text('当前渠道暂无更高版本'),
        findsOneWidget,
        reason: '${service.status} ${service.error}',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      service.dispose();
    },
  );
}
