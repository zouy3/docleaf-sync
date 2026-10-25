import 'dart:async';
import 'fakes.dart';

class ControlledReaderStore extends MemoryReaderStore {
  Completer<void>? writeGate;
  bool failNextWrite = false;
  bool failReadTime = false;
  final writes = <Map<String, dynamic>>[];

  ControlledReaderStore({super.entry});

  @override
  Future<void> addHistory(Map<String, dynamic> value) async {
    final snapshot = Map<String, dynamic>.from(value);
    await writeGate?.future;
    if (failNextWrite) {
      failNextWrite = false;
      throw StateError('History write failed');
    }
    writes.add(snapshot);
    await super.addHistory(snapshot);
  }

  @override
  Future<void> accumulateReadTime(
    String bookId,
    String kind,
    double seconds, {
    DateTime? at,
  }) async {
    if (failReadTime) throw StateError('Read time write failed');
    await super.accumulateReadTime(bookId, kind, seconds, at: at);
  }
}
