// ignore_for_file: invalid_use_of_internal_member, experimental_member_use

import 'package:meta/meta.dart';

import '../../sentry_flutter.dart';
import '../bindings/frame_callback_handler.dart';
import '../utils/internal_logger.dart';
import '../web/page_load/web_page_load.dart';

// TODO(buenaflor): marking this internal until we can find a robust way to unify the TTID/TTFD implementation as currently it is very fragmented.

/// A fallback app–start integration for platforms without built-in app-start timing.
///
/// The Sentry Cocoa and Android SDKs include calls to capture the
/// exact application start timestamp. Other platforms—such as web, desktop,
/// or any SDK that doesn’t (yet) expose app-start instrumentation can use this
/// integration as a reasonable alternative. It measures the duration from
/// integration call to the first completed frame.
@internal
class GenericAppStartIntegration extends Integration<SentryFlutterOptions> {
  GenericAppStartIntegration([
    FrameCallbackHandler? frameHandler,
    WebPageLoad? Function()? webPageLoadFactory,
  ]) : _framesHandler = frameHandler ?? DefaultFrameCallbackHandler(),
       _webPageLoadFactory = webPageLoadFactory ?? createWebPageLoad;

  final FrameCallbackHandler _framesHandler;
  final WebPageLoad? Function() _webPageLoadFactory;

  /// A page loads once. A later `SentryFlutter.init` on the same page must not
  /// report the time since the navigation as an app start.
  static bool _webPageLoadReported = false;

  @visibleForTesting
  static void resetWebPageLoad() => _webPageLoadReported = false;

  static const String integrationName = 'GenericAppStart';

  @override
  void call(Hub hub, SentryFlutterOptions options) {
    if (!options.isTracingEnabled()) return;

    if (options.traceLifecycle == SentryTraceLifecycle.stream) {
      final webPageLoad = _takeWebPageLoad(options);
      final appStartSpan = options.timeToDisplayTrackerV2.trackAppStart(
        startTimestamp: webPageLoad?.navigationStart,
      );
      if (webPageLoad != null) {
        _reportWebPageLoad(hub, appStartSpan, webPageLoad);
      }
      options.sdk.addIntegration(integrationName);
      return;
    }

    options.timeToDisplayTracker.prepareInitialDisplay(options.clock());

    _framesHandler.addPostFrameCallback((_) async {
      try {
        await options.timeToDisplayTracker.recordInitialDisplay(
          options.clock(),
        );

        // Note: we do not set app start transaction measurements (yet) on purpose
        // This integration is used for TTID/TTFD mainly
        // However this may change in the future.
      } catch (exception, stackTrace) {
        internalLogger.error(
          'An exception occurred while executing the $GenericAppStartIntegration',
          error: exception,
          stackTrace: stackTrace,
        );
        if (options.automatedTestMode) {
          rethrow;
        }
      }
    });

    options.sdk.addIntegration(integrationName);
  }

  WebPageLoad? _takeWebPageLoad(SentryFlutterOptions options) {
    if (!options.platform.isWeb || _webPageLoadReported) return null;
    final webPageLoad = _webPageLoadFactory();
    if (webPageLoad == null) return null;
    if (webPageLoad.navigationStart == null) {
      // Reading the spans stops the long task collection.
      webPageLoad.spans();
      return null;
    }
    _webPageLoadReported = true;
    return webPageLoad;
  }

  /// Adds what the browser recorded before the first frame to [appStartSpan].
  void _reportWebPageLoad(
    Hub hub,
    SentrySpanV2 appStartSpan,
    WebPageLoad webPageLoad,
  ) {
    _framesHandler.addPostFrameCallback((_) {
      try {
        // Always read the spans: it stops the long task collection.
        final spans = webPageLoad.spans();
        if (appStartSpan.isEnded) return;
        appStartSpan.setAttributes(webPageLoad.attributes());
        for (final span in spans) {
          hub
              .startInactiveSpan(
                span.name,
                parentSpan: appStartSpan,
                startTimestamp: span.startTimestamp,
                attributes: {
                  ...span.attributes,
                  SemanticAttributesConstants.sentryOp: SentryAttribute.string(
                    span.operation,
                  ),
                  SemanticAttributesConstants.sentryOrigin:
                      SentryAttribute.string(
                        SentryTraceOrigins.autoNavigationRouteObserver,
                      ),
                },
              )
              .end(endTimestamp: span.endTimestamp);
        }
      } catch (exception, stackTrace) {
        internalLogger.error(
          'An exception occurred while reporting the web page load',
          error: exception,
          stackTrace: stackTrace,
        );
      }
    });
  }
}
