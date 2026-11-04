import 'package:catol/services/case_conversation.dart';
import 'package:catol/services/catalyst_local_retrieval_service.dart';
import 'package:catol/xai_chatbot_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('live chat sends a message and shows the assistant reply', (
    tester,
  ) async {
    final conversation = CaseConversation.empty(service: _EmptyService());
    await tester.pumpWidget(
      MaterialApp(home: XaiChatbotScreen(conversation: conversation)),
    );
    expect(
      find.textContaining('Describe your legal concern to get started.'),
      findsOneWidget,
    );

    await tester.enterText(
      find.byType(TextField),
      'My landlord kept my deposit',
    );
    await tester.tap(find.byTooltip('Send question'));
    await tester.pumpAndSettle();

    expect(find.text('My landlord kept my deposit'), findsOneWidget);
    expect(find.textContaining('similar enough'), findsOneWidget);
    expect(find.text('Preview example'), findsNothing);
  });
}

class _EmptyService implements CatalystRetrievalService {
  @override
  Future<CatalystMatchResponse> matchConcern(String concern) async =>
      CatalystMatchResponse(
        originalQuery: concern,
        processedQuery: concern,
        results: const [],
        warning: 'No provision was similar enough.',
      );
}
