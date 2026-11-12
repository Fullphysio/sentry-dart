import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import '../../../sentry_flutter.dart';
import 'web_page_load.dart';

WebPageLoad? createWebPageLoad() => BrowserPageLoad(web.window);

/// The most spans of one kind reported for one page load.
const _maxSpansPerKind = 30;

const _scriptExtensions = ['.js', '.mjs', '.wasm'];

class BrowserPageLoad implements WebPageLoad {
  /// Starts to collect long tasks. The browser delivers the ones that happened
  /// before this call asynchronously, so collection must start before the
  /// first frame for [spans] to include them.
  BrowserPageLoad(this._window) {
    _observeLongTasks();
  }

  final web.Window _window;
  final List<web.PerformanceEntry> _longTasks = [];
  web.PerformanceObserver? _longTaskObserver;

  web.Performance get _performance => _window.performance;

  @override
  DateTime? get navigationStart {
    final timeOrigin = _performance.timeOrigin;
    if (timeOrigin <= 0) return null;
    return _timestamp(0);
  }

  @override
  Map<String, SentryAttribute> attributes() {
    final attributes = <String, SentryAttribute>{};

    final entries = _performance.getEntriesByType('navigation').toDart;
    if (entries.isNotEmpty) {
      final navigation = entries.first as web.PerformanceNavigationTiming;
      attributes['browser.performance.navigation.type'] =
          SentryAttribute.string(navigation.type);
      if (navigation.responseStart > 0) {
        attributes['browser.web_vital.ttfb.value'] = SentryAttribute.double(
          navigation.responseStart.toDouble(),
        );
      }
    }

    final connection = (_window.navigator as JSObject)['connection'];
    if (connection.isA<JSObject>()) {
      final object = connection as JSObject;
      final effectiveType = object['effectiveType'];
      if (effectiveType.isA<JSString>()) {
        attributes['network.connection.effective_type'] =
            SentryAttribute.string((effectiveType as JSString).toDart);
      }
      final rtt = object['rtt'];
      if (rtt.isA<JSNumber>()) {
        attributes['network.connection.rtt'] = SentryAttribute.int(
          (rtt as JSNumber).toDartInt,
        );
      }
      final downlink = object['downlink'];
      if (downlink.isA<JSNumber>()) {
        attributes['network.connection.downlink'] = SentryAttribute.double(
          (downlink as JSNumber).toDartDouble,
        );
      }
      final saveData = object['saveData'];
      if (saveData.isA<JSBoolean>()) {
        attributes['network.connection.save_data'] = SentryAttribute.bool(
          (saveData as JSBoolean).toDart,
        );
      }
    }

    return attributes;
  }

  @override
  List<WebPageLoadSpan> spans() {
    final observer = _longTaskObserver;
    if (observer != null) {
      _longTasks.addAll(observer.takeRecords().toDart);
      observer.disconnect();
      _longTaskObserver = null;
    }
    return [..._resourceSpans(), ..._measureSpans(), ..._longTaskSpans()];
  }

  List<WebPageLoadSpan> _resourceSpans() {
    final spans = <WebPageLoadSpan>[];
    for (final entry in _performance.getEntriesByType('resource').toDart) {
      if (spans.length >= _maxSpansPerKind) break;
      final resource = entry as web.PerformanceResourceTiming;
      final path = Uri.tryParse(resource.name)?.path;
      if (path == null || !_scriptExtensions.any(path.endsWith)) continue;
      // An aborted or unfinished request has no response end yet.
      if (resource.responseEnd < resource.startTime) continue;
      // Without `Timing-Allow-Origin` a cross-origin response hides its sizes
      // and reports them as 0.
      final hasSizes =
          resource.encodedBodySize > 0 || resource.decodedBodySize > 0;
      spans.add(
        WebPageLoadSpan(
          name: path,
          operation: 'resource.${resource.initiatorType}',
          startTimestamp: _timestamp(resource.startTime),
          endTimestamp: _timestamp(resource.responseEnd),
          attributes: {
            if (hasSizes) ...{
              'http.response_transfer_size': SentryAttribute.int(
                resource.transferSize,
              ),
              'http.response_content_length': SentryAttribute.int(
                resource.encodedBodySize,
              ),
              'http.decoded_response_content_length': SentryAttribute.int(
                resource.decodedBodySize,
              ),
            },
          },
        ),
      );
    }
    return spans;
  }

  List<WebPageLoadSpan> _measureSpans() => [
    for (final entry
        in _performance
            .getEntriesByType('measure')
            .toDart
            .take(_maxSpansPerKind))
      WebPageLoadSpan(
        name: entry.name,
        operation: 'measure',
        startTimestamp: _timestamp(entry.startTime),
        endTimestamp: _timestamp(entry.startTime + entry.duration),
      ),
  ];

  List<WebPageLoadSpan> _longTaskSpans() => [
    for (final entry in _longTasks.take(_maxSpansPerKind))
      WebPageLoadSpan(
        name: 'Main UI thread blocked',
        operation: 'ui.long-task',
        startTimestamp: _timestamp(entry.startTime),
        endTimestamp: _timestamp(entry.startTime + entry.duration),
      ),
  ];

  void _observeLongTasks() {
    try {
      final observer = web.PerformanceObserver(
        (web.PerformanceObserverEntryList list, JSAny? _) {
          final remaining = _maxSpansPerKind - _longTasks.length;
          _longTasks.addAll(list.getEntries().toDart.take(remaining));
        }.toJS,
      );
      observer.observe(
        web.PerformanceObserverInit(type: 'longtask', buffered: true),
      );
      _longTaskObserver = observer;
    } catch (_) {
      // The browser does not report long tasks.
    }
  }

  /// Converts milliseconds since the navigation start to a wall-clock time.
  DateTime _timestamp(num sinceNavigationStart) =>
      DateTime.fromMicrosecondsSinceEpoch(
        ((_performance.timeOrigin + sinceNavigationStart) * 1000).round(),
        isUtc: true,
      );
}
