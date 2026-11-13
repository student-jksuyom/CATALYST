import 'package:catol/user_input_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'empty required input shows validation and keeps button visible',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: UserInputScreen(onProcess: (_, _, _) async => true)),
      );

      final processButton = find.byKey(
        const ValueKey('process-concern-button'),
      );
      expect(
        tester
            .widget<Opacity>(
              find
                  .ancestor(of: processButton, matching: find.byType(Opacity))
                  .first,
            )
            .opacity,
        lessThan(1),
      );
      await tester.tap(processButton);
      await tester.pump();

      expect(find.text('Your main problem is required.'), findsOneWidget);
      expect(find.byKey(const ValueKey('main-problem-field')), findsOneWidget);
    },
  );

  testWidgets(
    'submits the main problem and optional context without rewriting',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? submittedMain;
      String? submittedContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => UserInputScreen(
                      onProcess: (_, main, supporting) async {
                        submittedMain = main;
                        submittedContext = supporting;
                        return false;
                      },
                    ),
                  ),
                ),
                child: const Text('Open input'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open input'));
      await tester.pumpAndSettle();

      Finder inputField(String key) => find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(TextField),
      );
      await tester.enterText(
        inputField('supporting-context-field'),
        'Nagbayad ako nang hulugan.',
      );
      await tester.enterText(
        inputField('main-problem-field'),
        'The seller did not deliver the appliance.',
      );
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('process-concern-button')));
      await tester.pumpAndSettle();

      expect(submittedMain, 'The seller did not deliver the appliance.');
      expect(submittedContext, 'Nagbayad ako nang hulugan.');
      expect(
        find.text('The seller did not deliver the appliance.'),
        findsOneWidget,
      );
      expect(find.text('Nagbayad ako nang hulugan.'), findsOneWidget);
    },
  );
}
