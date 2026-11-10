import 'dart:async';

import 'package:catol/legal_services_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> scrollTo(WidgetTester tester, String label) async {
    await tester.scrollUntilVisible(
      find.text(label),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.pumpAndSettle();
    expect(find.text('Open Google Maps?'), findsOneWidget);
    await tester.tap(find.text('Open Google Maps'));
    await tester.pumpAndSettle();
  }

  test('search URL encodes the service and entered area', () {
    final uri = legalServicesSearchUri(
      LegalServiceType.legalAid,
      'Calamba, Laguna & nearby',
    );
    expect(uri.scheme, 'https');
    expect(uri.host, 'www.google.com');
    expect(uri.path, '/maps/search/');
    expect(uri.queryParameters['api'], '1');
    expect(
      uri.queryParameters['query'],
      'legal aid services near Calamba, Laguna & nearby',
    );
  });

  testWidgets('map preview is taller without changing horizontal padding', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: LegalServicesScreen(preview: Text('Preview placeholder')),
      ),
    );
    final size = tester.getSize(
      find.byKey(const ValueKey('legal-services-map-preview')),
    );
    expect(size.height, 400);
    expect(
      size.width,
      tester.view.physicalSize.width / tester.view.devicePixelRatio - 48,
    );
  });

  testWidgets('preview explains its fixed-area and location limitations', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: LegalServicesScreen(preview: Text('Preview placeholder')),
      ),
    );
    expect(
      find.textContaining('fixed-area Google Maps preview'),
      findsOneWidget,
    );
    expect(find.text('Show my location'), findsNothing);
  });

  testWidgets('city search opens Google Maps without requesting location', (
    tester,
  ) async {
    Uri? opened;
    var locationRequested = false;
    await tester.pumpWidget(
      MaterialApp(
        home: LegalServicesScreen(
          preview: const Text('Preview placeholder'),
          locate: () async {
            locationRequested = true;
            return const SearchLocation(14, 121);
          },
          openMap: (uri) async {
            opened = uri;
            return true;
          },
        ),
      ),
    );

    await scrollTo(tester, 'Lawyers and Law Offices');
    await tester.tap(find.text('Lawyers and Law Offices'));
    await scrollTo(tester, 'City or municipality');
    await tester.enterText(find.byType(TextField), ' Calamba, Laguna ');
    await scrollTo(tester, 'Search this area in Google Maps');
    await tester.tap(find.text('Search this area in Google Maps'));
    await confirm(tester);

    expect(locationRequested, isFalse);
    expect(
      opened!.queryParameters['query'],
      'lawyers and law offices near Calamba, Laguna',
    );
  });

  testWidgets('location search sends rounded location for selected service', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    Uri? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: LegalServicesScreen(
          preview: const Text('Preview placeholder'),
          locate: () async => const SearchLocation(14.34567, 121.32024),
          openMap: (uri) async {
            opened = uri;
            return true;
          },
        ),
      ),
    );
    await scrollTo(tester, 'Legal aid services');
    await tester.tap(find.text('Legal aid services'));
    await scrollTo(tester, 'Search using my location');
    await tester.tap(find.text('Search using my location'));
    await confirm(tester);
    expect(
      opened!.queryParameters['query'],
      'legal aid services near 14.346,121.320',
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android location uses centered map intent with URL fallback', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final opened = <Uri>[];
    await tester.pumpWidget(
      MaterialApp(
        home: LegalServicesScreen(
          preview: const Text('Preview placeholder'),
          locate: () async => const SearchLocation(14.34567, 121.32024),
          openMap: (uri) async {
            opened.add(uri);
            return opened.length > 1;
          },
        ),
      ),
    );
    await scrollTo(tester, 'Search using my location');
    await tester.tap(find.text('Search using my location'));
    await confirm(tester);
    expect(opened, hasLength(2));
    expect(opened.first.scheme, 'geo');
    expect(opened.first.path, '14.346,121.320');
    expect(opened.first.queryParameters['q'], "Public Attorney's Office");
    expect(opened.last.scheme, 'https');
    expect(
      opened.last.queryParameters['query'],
      "Public Attorney's Office near 14.346,121.320",
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('denied location displays error and allows city fallback', (
    tester,
  ) async {
    Uri? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: LegalServicesScreen(
          preview: const Text('Preview placeholder'),
          locate: () async => throw const LocationSearchException(
            'Location permission was denied. You can search by city instead.',
          ),
          openMap: (uri) async {
            opened = uri;
            return true;
          },
        ),
      ),
    );
    await scrollTo(tester, 'Search using my location');
    await tester.tap(find.text('Search using my location'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Location permission was denied'),
      findsOneWidget,
    );
    expect(opened, isNull);

    await scrollTo(tester, 'City or municipality');
    await tester.enterText(find.byType(TextField), 'Manila');
    await scrollTo(tester, 'Search this area in Google Maps');
    await tester.tap(find.text('Search this area in Google Maps'));
    await confirm(tester);
    expect(
      opened!.queryParameters['query'],
      "Public Attorney's Office near Manila",
    );
    expect(find.byKey(const ValueKey('legal-services-error')), findsNothing);
  });

  testWidgets('empty city and failed launcher report errors', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LegalServicesScreen(
          preview: const Text('Preview placeholder'),
          locate: () async => const SearchLocation(14, 121),
          openMap: (_) async => false,
        ),
      ),
    );
    await scrollTo(tester, 'Search this area in Google Maps');
    await tester.tap(find.text('Search this area in Google Maps'));
    await tester.pumpAndSettle();
    expect(
      find.text('Enter a city or municipality to search.'),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextField), 'Manila');
    await tester.tap(find.text('Search this area in Google Maps'));
    await confirm(tester);
    expect(
      find.text('Could not open Google Maps or a browser.'),
      findsOneWidget,
    );
  });

  testWidgets('search buttons are disabled while waiting for location', (
    tester,
  ) async {
    final pending = Completer<SearchLocation>();
    var requests = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: LegalServicesScreen(
          preview: const Text('Preview placeholder'),
          locate: () {
            requests++;
            return pending.future;
          },
          openMap: (_) async => true,
        ),
      ),
    );
    await scrollTo(tester, 'Search using my location');
    await tester.tap(find.text('Search using my location'));
    await tester.pump();
    expect(find.text('Preparing search...'), findsOneWidget);
    expect(requests, 1);
    pending.complete(const SearchLocation(14, 121));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Search using my location'), findsOneWidget);
  });

  testWidgets('cancelling confirmation does not open a map', (tester) async {
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: LegalServicesScreen(
          preview: const Text('Preview placeholder'),
          openMap: (_) async {
            opened = true;
            return true;
          },
        ),
      ),
    );
    expect(find.text('Preview placeholder'), findsOneWidget);
    await scrollTo(tester, 'City or municipality');
    await tester.enterText(find.byType(TextField), 'Manila');
    await scrollTo(tester, 'Search this area in Google Maps');
    await tester.tap(find.text('Search this area in Google Maps'));
    await tester.pumpAndSettle();
    expect(find.text('Open Google Maps?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(opened, isFalse);
    expect(find.text('Manila'), findsOneWidget);
  });
}
