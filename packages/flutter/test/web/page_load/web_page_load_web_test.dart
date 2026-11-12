@TestOn('browser')
library;

import 'dart:js_interop';

import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/src/web/page_load/web_page_load.dart';
import 'package:sentry_flutter/src/web/page_load/web_page_load_web.dart'
    show BrowserPageLoad;
import 'package:web/web.dart' as web;

void main() {
  group(BrowserPageLoad, () {
    late BrowserPageLoad sut;

    setUp(() {
      sut = BrowserPageLoad(web.window);
    });

    test('createWebPageLoad returns the browser implementation', () {
      expect(createWebPageLoad(), isA<BrowserPageLoad>());
    });

    test('navigation start is the browser time origin', () {
      final navigationStart = sut.navigationStart!;

      expect(navigationStart.isUtc, isTrue);
      expect(
        navigationStart.millisecondsSinceEpoch,
        closeTo(web.window.performance.timeOrigin, 1),
      );
      expect(navigationStart.isBefore(DateTime.now()), isTrue);
    });

    test('attributes describe the navigation', () {
      final attributes = sut.attributes();

      expect(
        attributes['browser.performance.navigation.type']?.value,
        isA<String>(),
      );
    });

    test('reports performance measures as spans', () {
      final performance = web.window.performance;
      performance.mark('sentry-test-start');
      performance.mark('sentry-test-end');
      performance.measure(
        'sentry-test-measure',
        'sentry-test-start'.toJS,
        'sentry-test-end',
      );

      final span = sut.spans().singleWhere(
        (span) => span.name == 'sentry-test-measure',
      );

      expect(span.operation, 'measure');
      expect(span.startTimestamp.isBefore(sut.navigationStart!), isFalse);
      expect(span.endTimestamp.isBefore(span.startTimestamp), isFalse);
    });

    test('reports script resources as spans with their sizes', () {
      final scripts = sut.spans().where(
        (span) => span.operation.startsWith('resource.'),
      );

      expect(scripts, isNotEmpty);
      for (final script in scripts) {
        expect(script.name, matches(RegExp(r'\.(js|mjs|wasm)$')));
        expect(script.endTimestamp.isBefore(script.startTimestamp), isFalse);
        final transferSize = script.attributes['http.response_transfer_size'];
        if (transferSize != null) {
          expect(transferSize.value, isA<int>());
          expect(
            script.attributes['http.decoded_response_content_length'],
            isNotNull,
          );
        }
      }
    });

    test('reports long tasks collected since its creation', () async {
      final end = DateTime.now().add(const Duration(milliseconds: 120));
      while (DateTime.now().isBefore(end)) {}
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final tasks = sut.spans().where(
        (span) => span.operation == 'ui.long-task',
      );

      expect(tasks, isNotEmpty);
      for (final task in tasks) {
        expect(task.name, 'Main UI thread blocked');
        expect(task.endTimestamp.isAfter(task.startTimestamp), isTrue);
      }
    });

    test('stops collecting long tasks after spans are read', () async {
      int longTaskCount() =>
          sut.spans().where((span) => span.operation == 'ui.long-task').length;
      final before = longTaskCount();

      final end = DateTime.now().add(const Duration(milliseconds: 120));
      while (DateTime.now().isBefore(end)) {}
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(longTaskCount(), before);
    });
  });
}
