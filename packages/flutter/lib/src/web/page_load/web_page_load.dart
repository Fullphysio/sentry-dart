import 'package:meta/meta.dart';

import '../../../sentry_flutter.dart';

export 'web_page_load_stub.dart'
    if (dart.library.js_interop) 'web_page_load_web.dart';

/// What the browser recorded about the page load before the SDK started.
///
/// The Flutter engine, `main.dart.js` and the SDK itself load after the
/// navigation started, so the SDK cannot time this part on its own.
@internal
abstract class WebPageLoad {
  /// When the browser started to navigate to the page.
  DateTime? get navigationStart;

  /// Attributes describing the navigation and the network connection.
  Map<String, SentryAttribute> attributes();

  /// Script resources, `performance.measure` entries and long tasks recorded
  /// so far. Stops collecting long tasks.
  List<WebPageLoadSpan> spans();
}

/// A finished span rebuilt from a browser performance entry.
@internal
class WebPageLoadSpan {
  WebPageLoadSpan({
    required this.name,
    required this.operation,
    required this.startTimestamp,
    required this.endTimestamp,
    this.attributes = const {},
  });

  final String name;
  final String operation;
  final DateTime startTimestamp;
  final DateTime endTimestamp;
  final Map<String, SentryAttribute> attributes;
}
