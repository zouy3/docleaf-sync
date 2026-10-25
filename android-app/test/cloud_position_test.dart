import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/cloud_position.dart';
import 'package:fqapp/widgets/reader/reader_chapter_layout.dart';

ReaderContentBlock block(int index, String text, int start, {int? id}) =>
    ReaderContentBlock(
      index: index,
      text: text,
      start: start,
      legacyStart: start,
      top: 0,
      height: 30,
      span: TextSpan(text: text),
      align: TextAlign.start,
      lines: const [],
      paraIndex: id,
    );

void main() {
  test('quote does not split an emoji at either boundary', () {
    final text = '${'中' * 31}😀';
    expect(
      captureCloudPosition([block(1, text, 0)], 0, '456', 0, '第一章')!['quote'],
      '中' * 31,
    );
    expect(
      captureCloudPosition([block(1, '😀正文', 0)], 1, '456', 0, '第一章')!['quote'],
      '😀正文',
    );
  });
  test(
    'canonical text strips whitespace but preserves UTF-16 emoji length',
    () {
      expect(canonicalReadingText('　中 文\n😀\u200b'), '中文😀');
      expect(canonicalReadingText('😀').length, 2);
    },
  );
  test('position is independent of page dimensions and indentation', () {
    final old = [
      block(0, '标题', 0),
      block(1, '　　第一段文字', 3, id: 5),
      block(2, '　　第二段测试文字', 20, id: 6),
    ];
    final cursor = captureCloudPosition(old, 25, '456', 0, '第一章')!;
    expect(cursor['character_offset'], 3);
    expect(cursor['paragraph_id'], '6');
    final changed = [
      block(0, '标题', 0),
      block(1, '第一段文字', 3, id: 5),
      block(2, '第二段测试文字', 50, id: 6),
    ];
    expect(resolveCloudPosition(changed, cursor), 53);
  });
  test('quote restores when upstream paragraph IDs are unavailable', () {
    final cursor = {
      'paragraph_id': null,
      'ordinal': 0,
      'character_offset': 3,
      'quote': '测试文字',
    };
    expect(
      resolveCloudPosition([
        block(0, '标题', 0),
        block(1, '前一段', 3),
        block(2, '第二段测试文字', 20),
      ], cursor),
      23,
    );
  });
  test('empty chapter has no false position', () {
    expect(
      captureCloudPosition([block(0, '标题', 0)], 0, '456', 0, '标题'),
      isNull,
    );
    expect(resolveCloudPosition([], {}), isNull);
  });
}
