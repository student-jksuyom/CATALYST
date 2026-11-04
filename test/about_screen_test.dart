import 'package:catol/about_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows About content, legal sources, and app identification', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: AboutScreen()));

    expect(find.text('About'), findsOneWidget);
    expect(find.text('Civil Code of the Philippines'), findsOneWidget);
    expect(find.text('Family Code of the Philippines'), findsOneWidget);
    expect(find.text('Consumer Act of the Philippines'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -700));
    await tester.pumpAndSettle();
    expect(find.text('CATALYST v1.0'), findsOneWidget);
    expect(find.text('Case-to-Law Matching System'), findsOneWidget);

    final noticeText = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((richText) => richText.text.toPlainText())
        .join(' ');
    expect(
      noticeText,
      contains(
        'CATALYST is designed to assist users in understanding potentially '
        'applicable laws. It does not replace professional legal advice, '
        'legal representation, or the judgment of a qualified legal '
        'practitioner.',
      ),
    );
  });

  testWidgets('uses the supplied header image and About heading style', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: AboutScreen()));

    final logoImage = tester.widget<Image>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Image &&
            widget.image is AssetImage &&
            (widget.image as AssetImage).assetName ==
                'assets/images/catalyst_header.png',
      ),
    );
    expect(
      (logoImage.image as AssetImage).assetName,
      'assets/images/catalyst_header.png',
    );

    final aboutTitle = tester.widget<Text>(find.text('About'));
    expect(aboutTitle.style?.fontFamily, 'Montserrat');
    expect(aboutTitle.style?.color, const Color(0xFF1A307F));
  });

  testWidgets('back button returns to the previous route', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (context) => const AboutScreen(),
                  ),
                );
              },
              child: const Text('Open About'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open About'));
    await tester.pumpAndSettle();
    expect(find.text('About'), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Open About'), findsOneWidget);
  });
}
