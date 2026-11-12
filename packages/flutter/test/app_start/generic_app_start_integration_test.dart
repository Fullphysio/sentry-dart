// ignore_for_file: invalid_use_of_internal_member, experimental_member_use

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:sentry_flutter/src/app_start/generic_app_start_integration.dart';
import 'package:sentry_flutter/src/navigation/time_to_display_tracker.dart';
import 'package:sentry_flutter/src/navigation/time_to_display_tracker_v2.dart';
import 'package:sentry_flutter/src/web/page_load/web_page_load.dart';
import 'package:sentry/src/platform/mock_platform.dart';
// Internal import is fine in tests.
import 'package:sentry/src/telemetry/span/transaction/sentry_tracer.dart';

import '../bindings/fake_frame_callback_handler.dart';
import '../mocks.dart';

void main() {
  group('GenericAppStartIntegration (real impl)', () {
    late Fixture fixture;

    setUp(() {
      fixture = Fixture();
      fixture.options.traceLifecycle = SentryTraceLifecycle.static;
    });

    group('when tracing is enabled', () {
      setUp(() {
        fixture.options.tracesSampleRate = 1.0;
      });

      test('adds sdk integration', () {
        final sut = fixture.getSut();

        sut.call(fixture.hub, fixture.options);

        expect(fixture.options.sdk.integrations, contains('GenericAppStart'));
      });

      test('sets transaction ID on timeToDisplayTracker', () {
        final sut = fixture.getSut();

        sut.call(fixture.hub, fixture.options);

        expect(fixture.options.timeToDisplayTracker.transactionId, isNotNull);
      });

      test('adds post frame callback', () {
        final sut = fixture.getSut();

        sut.call(fixture.hub, fixture.options);

        expect(fixture.fakeFrameHandler.postFrameCallback, isNotNull);
      });

      test(
        'creates transaction with correct context when frame callback executes',
        () async {
          final sut = fixture.getSut();
          fixture.fakeFrameHandler.postFrameCallbackDelay = Duration.zero;

          sut.call(fixture.hub, fixture.options);

          await Future<void>.delayed(Duration(milliseconds: 10));

          final tracer = fixture.hub.scope.span as SentryTracer?;
          expect(tracer, isNotNull);
          expect(tracer!.name, 'root /');
          expect(tracer.context.operation, SentrySpanOperations.uiLoad);
          expect(tracer.origin, SentryTraceOrigins.autoUiTimeToDisplay);
          expect(
            tracer.transactionNameSource,
            SentryTransactionNameSource.component,
          );
        },
      );

      test('tracks time to display when frame callback executes', () async {
        final sut = fixture.getSut();
        fixture.fakeFrameHandler.postFrameCallbackDelay = Duration.zero;

        sut.call(fixture.hub, fixture.options);

        await Future<void>.delayed(Duration(milliseconds: 100));

        final tracer = fixture.hub.scope.span as SentryTracer?;
        final hasTtidSpan = tracer!.children.any(
          (span) =>
              span.context.operation ==
              SentrySpanOperations.uiTimeToInitialDisplay,
        );
        expect(hasTtidSpan, isTrue);
      });

      test('finishes transaction when frame callback executes', () async {
        final sut = fixture.getSut();
        fixture.fakeFrameHandler.postFrameCallbackDelay = Duration.zero;

        sut.call(fixture.hub, fixture.options);

        // Wait longer than autoFinishAfter (3s) + delay to ensure finish.
        await Future<void>.delayed(Duration(seconds: 4));

        final envelopes = fixture.fakeTransport.envelopes;
        expect(envelopes.length, 1);
        final capturedTransaction = await _transactionFromEnvelope(
          envelopes.first,
        );
        final spans = capturedTransaction['spans'] as List;
        final span = spans.first as Map<dynamic, dynamic>;
        expect(span['op'], SentrySpanOperations.uiTimeToInitialDisplay);
        expect(span['description'], 'root / initial display');
        expect(
          capturedTransaction['contexts']['trace']['op'],
          SentrySpanOperations.uiLoad,
        );
        expect(
          capturedTransaction['contexts']['trace']['origin'],
          SentryTraceOrigins.autoUiTimeToDisplay,
        );
      });

      test('uses correct start timestamp from clock', () async {
        final fixedTime = DateTime(2023, 1, 1, 12, 0, 0).toUtc();
        fixture.options.clock = () => fixedTime;
        final sut = fixture.getSut();
        fixture.fakeFrameHandler.postFrameCallbackDelay = Duration.zero;

        sut.call(fixture.hub, fixture.options);

        await Future<void>.delayed(Duration(milliseconds: 100));

        final tracer = fixture.hub.scope.span as SentryTracer?;
        expect(tracer, isNotNull);
        expect(tracer!.startTimestamp, fixedTime);
      });

      test('uses clock for end timestamp in frame callback', () async {
        var callCount = 0;
        final startTime = DateTime(2023, 1, 1, 12, 0, 0).toUtc();
        final endTime = DateTime(2023, 1, 1, 12, 0, 1).toUtc();
        fixture.options.clock = () {
          callCount++;
          return callCount == 1 ? startTime : endTime;
        };

        final sut = fixture.getSut();
        fixture.fakeFrameHandler.postFrameCallbackDelay = Duration.zero;

        sut.call(fixture.hub, fixture.options);

        // Wait longer than autoFinishAfter (3s) + delay to ensure finish.
        await Future<void>.delayed(Duration(seconds: 4));

        final envelopes = fixture.fakeTransport.envelopes;
        expect(envelopes.length, 1);
        final capturedTransaction = await _transactionFromEnvelope(
          envelopes.first,
        );
        final spans = capturedTransaction['spans'] as List;
        final span = spans.first as Map<dynamic, dynamic>;
        expect(span['op'], SentrySpanOperations.uiTimeToInitialDisplay);
        expect(span['description'], 'root / initial display');

        // Compare TTID span times
        final ttidStartTimestamp = DateTime.parse(
          span['start_timestamp'].toString(),
        );
        final ttidEndTimestamp = DateTime.parse(span['timestamp'].toString());
        expect(ttidStartTimestamp, startTime);
        expect(ttidEndTimestamp, endTime);

        // Compare transaction times
        final transactionStartTimestamp = DateTime.parse(
          capturedTransaction['start_timestamp'].toString(),
        );
        final transactionEndTimestamp = DateTime.parse(
          capturedTransaction['timestamp'].toString(),
        );
        expect(transactionStartTimestamp, startTime);
        expect(transactionEndTimestamp, endTime);
      });

      test(
        'names the reserved transaction after a non-root initial route',
        () async {
          final sut = fixture.getSut();
          final observer = SentryNavigatorObserver(hub: fixture.hub);

          sut.call(fixture.hub, fixture.options);
          // The initial route is pushed while the first frame is being built,
          // so it always precedes the post frame callback.
          observer.didPush(fixture.route('/login'), null);
          fixture.fakeFrameHandler.postFrameCallback!(Duration.zero);
          await pumpEventQueue();

          final tracer = fixture.hub.scope.span as SentryTracer?;
          expect(tracer?.name, '/login');
          expect(tracer?.origin, SentryTraceOrigins.autoUiTimeToDisplay);
          expect(
            tracer?.children.map((span) => span.context.description),
            contains('/login initial display'),
          );
        },
      );

      test(
        'maintains transaction ID consistency between setup and tracking',
        () async {
          final sut = fixture.getSut();
          fixture.fakeFrameHandler.postFrameCallbackDelay = Duration.zero;

          sut.call(fixture.hub, fixture.options);

          final transactionIdAfterSetup =
              fixture.options.timeToDisplayTracker.transactionId;
          expect(transactionIdAfterSetup, isNotNull);

          await Future<void>.delayed(Duration(milliseconds: 10));

          final tracer = fixture.hub.scope.span as SentryTracer?;
          expect(tracer, isNotNull);
          expect(tracer!.context.spanId, transactionIdAfterSetup);
        },
      );
    });

    group('when tracing is disabled', () {
      setUp(() {
        fixture.options.tracesSampleRate = null;
      });

      test('does not add sdk integration', () {
        final sut = fixture.getSut();

        sut.call(fixture.hub, fixture.options);

        expect(fixture.options.sdk.integrations, isEmpty);
      });

      test('does not set transaction ID on timeToDisplayTracker', () {
        final sut = fixture.getSut();

        sut.call(fixture.hub, fixture.options);

        expect(fixture.options.timeToDisplayTracker.transactionId, isNull);
      });

      test('does not add post frame callback', () {
        final sut = fixture.getSut();

        sut.call(fixture.hub, fixture.options);

        expect(fixture.fakeFrameHandler.postFrameCallback, isNull);
      });

      test('does not create any transactions', () {
        final sut = fixture.getSut();

        sut.call(fixture.hub, fixture.options);

        expect(fixture.hub.scope.span, isNull);
      });
    });

    group('integration constants', () {
      test('has correct integration name', () {
        expect(GenericAppStartIntegration.integrationName, 'GenericAppStart');
      });
    });
  });

  group('GenericAppStartIntegration V2 (streaming)', () {
    late Fixture fixture;

    setUp(() {
      fixture = Fixture();
      fixture.options.tracesSampleRate = 1.0;
      fixture.options.traceLifecycle = SentryTraceLifecycle.stream;
      fixture.options.timeToDisplayTrackerV2 = TimeToDisplayTrackerV2(
        hub: fixture.hub,
        frameCallbackHandler: fixture.fakeFrameHandler,
      );
    });

    test('adds sdk integration', () {
      final sut = fixture.getSut();

      sut.call(fixture.hub, fixture.options);

      expect(fixture.options.sdk.integrations, contains('GenericAppStart'));
    });

    test('sets app start span as active span', () {
      final sut = fixture.getSut();

      sut.call(fixture.hub, fixture.options);

      final activeSpan = fixture.hub.getActiveSpan();
      expect(activeSpan, isNotNull);
      expect(activeSpan!.name, 'root /');
    });

    test('does not create V1 transaction', () {
      final sut = fixture.getSut();

      sut.call(fixture.hub, fixture.options);

      expect(fixture.hub.scope.span, isNull);
    });

    test('does not register own post frame callback', () {
      final integrationFrameHandler = FakeFrameCallbackHandler();
      final sut = GenericAppStartIntegration(integrationFrameHandler);

      sut.call(fixture.hub, fixture.options);

      expect(integrationFrameHandler.postFrameCallback, isNull);
    });

    group('on web', () {
      final navigationStart = DateTime.utc(2026, 1, 1, 12);
      late FakeFrameCallbackHandler integrationFrameHandler;
      late _FakeWebPageLoad webPageLoad;
      late List<RecordingSentrySpanV2> endedSpans;

      GenericAppStartIntegration getWebSut() => GenericAppStartIntegration(
        integrationFrameHandler,
        () => webPageLoad,
      );

      setUp(() {
        GenericAppStartIntegration.resetWebPageLoad();
        fixture.options.platform = MockPlatform.linux(isWeb: true);
        integrationFrameHandler = FakeFrameCallbackHandler();
        webPageLoad = _FakeWebPageLoad(navigationStart);
        endedSpans = [];
        fixture.options.lifecycleRegistry.registerCallback<OnProcessSpan>((
          event,
        ) {
          if (event.span case final RecordingSentrySpanV2 span) {
            endedSpans.add(span);
          }
        });
      });

      test('starts the app start span at the navigation start', () {
        getWebSut().call(fixture.hub, fixture.options);

        expect(fixture.hub.getActiveSpan()!.startTimestamp, navigationStart);
      });

      test('adds the page load attributes after the first frame', () {
        getWebSut().call(fixture.hub, fixture.options);
        final appStartSpan = fixture.hub.getActiveSpan()!;

        expect(appStartSpan.attributes['browser.web_vital.ttfb.value'], isNull);

        integrationFrameHandler.postFrameCallback!(Duration.zero);

        expect(
          appStartSpan.attributes['browser.web_vital.ttfb.value']?.value,
          120.0,
        );
      });

      test('adds resources, measures and long tasks as child spans', () {
        getWebSut().call(fixture.hub, fixture.options);
        final appStartSpan = fixture.hub.getActiveSpan()!;

        integrationFrameHandler.postFrameCallback!(Duration.zero);

        final operations = {
          for (final span in endedSpans)
            span.name:
                span.attributes[SemanticAttributesConstants.sentryOp]?.value,
        };
        expect(operations['/main.dart.js'], 'resource.script');
        expect(operations['flutter.engine_init'], 'measure');
        expect(operations['Main UI thread blocked'], 'ui.long-task');
        expect(
          endedSpans
              .where((span) => span.name == '/main.dart.js')
              .single
              .parentSpan,
          appStartSpan,
        );
      });

      test('adds nothing when the app start span ended before the frame', () {
        getWebSut().call(fixture.hub, fixture.options);
        final appStartSpan = fixture.hub.getActiveSpan()!;

        appStartSpan.end();
        endedSpans.clear();
        integrationFrameHandler.postFrameCallback!(Duration.zero);

        expect(endedSpans, isEmpty);
        expect(appStartSpan.attributes['browser.web_vital.ttfb.value'], isNull);
        expect(webPageLoad.spansReadCount, 1);
      });

      test('stops the long task collection without a navigation start', () {
        webPageLoad = _FakeWebPageLoad(null);

        getWebSut().call(fixture.hub, fixture.options);

        expect(webPageLoad.spansReadCount, 1);
        expect(integrationFrameHandler.postFrameCallback, isNull);
      });

      test('reports the page load once per page', () {
        getWebSut().call(fixture.hub, fixture.options);
        fixture.hub.getActiveSpan()!.end();

        final secondFrameHandler = FakeFrameCallbackHandler();
        fixture.options.timeToDisplayTrackerV2 = TimeToDisplayTrackerV2(
          hub: fixture.hub,
          frameCallbackHandler: fixture.fakeFrameHandler,
        );
        GenericAppStartIntegration(
          secondFrameHandler,
          () => webPageLoad,
        ).call(fixture.hub, fixture.options);

        expect(secondFrameHandler.postFrameCallback, isNull);
        expect(
          fixture.hub.getActiveSpan()!.startTimestamp,
          isNot(navigationStart),
        );
      });

      test('does not read the page load on other platforms', () {
        fixture.options.platform = MockPlatform.linux();

        getWebSut().call(fixture.hub, fixture.options);

        expect(integrationFrameHandler.postFrameCallback, isNull);
        expect(
          fixture.hub.getActiveSpan()!.startTimestamp,
          isNot(navigationStart),
        );
      });
    });
  });
}

class Fixture {
  Fixture() {
    options = defaultTestOptions();
    options.transport = fakeTransport;
    hub = Hub(options);
    options.timeToDisplayTracker = TimeToDisplayTracker(
      hub: hub,
      options: options,
    );
  }

  final fakeTransport = _FakeTransport();
  late final SentryFlutterOptions options;
  late final Hub hub;
  final fakeFrameHandler = FakeFrameCallbackHandler();

  GenericAppStartIntegration getSut() {
    return GenericAppStartIntegration(fakeFrameHandler);
  }

  PageRoute<dynamic> route(String? name) => PageRouteBuilder<void>(
    pageBuilder: (_, _, _) => const SizedBox.shrink(),
    settings: RouteSettings(name: name),
  );
}

class _FakeWebPageLoad implements WebPageLoad {
  _FakeWebPageLoad(this.navigationStart);

  @override
  final DateTime? navigationStart;

  WebPageLoadSpan span(String name, String operation) => WebPageLoadSpan(
    name: name,
    operation: operation,
    startTimestamp: navigationStart!.add(const Duration(milliseconds: 10)),
    endTimestamp: navigationStart!.add(const Duration(milliseconds: 90)),
  );

  @override
  Map<String, SentryAttribute> attributes() => {
    'browser.web_vital.ttfb.value': SentryAttribute.double(120),
  };

  int spansReadCount = 0;

  @override
  List<WebPageLoadSpan> spans() {
    spansReadCount++;
    if (navigationStart == null) return const [];
    return [
      span('/main.dart.js', 'resource.script'),
      span('flutter.engine_init', 'measure'),
      span('Main UI thread blocked', 'ui.long-task'),
    ];
  }
}

class _FakeTransport implements Transport {
  final envelopes = <SentryEnvelope>[];

  @override
  Future<SentryId?> send(SentryEnvelope envelope) {
    envelopes.add(envelope);
    return Future.value(SentryId.empty());
  }
}

Future<Map<String, dynamic>> _transactionFromEnvelope(
  SentryEnvelope envelope,
) async {
  final data = await envelope.items.first.dataFactory();
  final utf8Data = utf8.decode(data);
  final envelopeItemJson = jsonDecode(utf8Data);
  return envelopeItemJson as Map<String, dynamic>;
}
