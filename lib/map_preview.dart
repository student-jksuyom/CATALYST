import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

const _mapUrl =
    'https://www.google.com/maps/embed?pb=!1m14!1m12!1m3!1d15461.644813910107!2d121.32024320000001!3d14.345598549999997!2m3!1f0!2f0!3f0!3m2!1i1024!2i768!4f13.1!5e0!3m2!1sen!2sph!4v1794247998758!5m2!1sen!2sph';

const _mapHtml =
    '''
<!doctype html>
<html><head>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>html, body { margin: 0; height: 100%; } iframe { width: 100%; height: 100%; border: 0; }</style>
</head><body>
<iframe src="$_mapUrl" allowfullscreen loading="eager"
  referrerpolicy="strict-origin-when-cross-origin"></iframe>
</body></html>
''';

class MapPreview extends StatefulWidget {
  const MapPreview({super.key});

  @override
  State<MapPreview> createState() => _MapPreviewState();
}

class _MapPreviewState extends State<MapPreview> {
  WebViewController? _controller;
  var _loading = true;
  var _failed = false;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      _initialize();
    }
  }

  Future<void> _initialize() async {
    try {
      final controller = WebViewController();
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (mounted && !_failed) setState(() => _loading = false);
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame != true) return;
            developer.log(
              'Map preview load failed (${error.errorCode})',
              name: 'catol.map_preview',
            );
            if (mounted) setState(() => _failed = true);
          },
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (request.url == 'about:blank' ||
                uri != null &&
                    uri.scheme == 'https' &&
                    uri.host == 'www.google.com' &&
                    uri.path == '/maps/embed') {
              return NavigationDecision.navigate;
            }
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Use the search options below to open Google Maps.',
                  ),
                ),
              );
            }
            return NavigationDecision.prevent;
          },
        ),
      );
      if (!mounted) return;
      setState(() => _controller = controller);
      await controller.loadHtmlString(_mapHtml);
    } catch (error, stackTrace) {
      developer.log(
        'Map preview initialization failed (${error.runtimeType})',
        name: 'catol.map_preview',
        stackTrace: stackTrace,
      );
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      return const Center(
        child: Text('Map preview is available on Android and iOS.'),
      );
    }
    if (_failed) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Map preview unavailable. Check your connection.'),
            TextButton(
              onPressed: () {
                setState(() {
                  _loading = true;
                  _failed = false;
                  _controller = null;
                });
                _initialize();
              },
              child: const Text('Retry preview'),
            ),
          ],
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        children: [
          if (_controller != null)
            WebViewWidget(
              controller: _controller!,
              gestureRecognizers: {
                Factory<OneSequenceGestureRecognizer>(
                  () => EagerGestureRecognizer(),
                ),
              },
            ),
          if (_loading) const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
