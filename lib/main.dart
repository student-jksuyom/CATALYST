import 'dart:developer' as developer;

import 'package:flutter/material.dart';

import 'about_screen.dart';
import 'history_screen.dart';
import 'home_screen.dart';
import 'landing_screen.dart';
import 'law_details_screen.dart';
import 'legal_services_screen.dart';
import 'match_results_screen.dart';
import 'models/history_entry.dart';
import 'models/law_match_result.dart';
import 'processing_screen.dart';
import 'services/case_conversation.dart';
import 'services/catalyst_local_retrieval_service.dart';
import 'services/followup_service.dart';
import 'services/history_store.dart';
import 'services/query_analysis.dart';
import 'xai_chatbot_screen.dart';

void main() {
  runApp(CatalystApp());
}

class CatalystApp extends StatelessWidget {
  CatalystApp({
    super.key,
    CatalystRetrievalService? retrievalService,
    FollowUpAnswerer? followUp,
    HistoryStore? historyStore,
  }) : retrievalService =
           retrievalService ?? const LocalSemanticRetrievalService(),
       followUp = followUp ?? createDefaultFollowUpAnswerer(),
       historyStore = historyStore ?? HistoryStore();

  final CatalystRetrievalService retrievalService;
  final FollowUpAnswerer? followUp;
  final HistoryStore historyStore;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CATALYST',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFFF2FEFF),
        useMaterial3: true,
      ),
      home: LandingScreen(homeBuilder: _buildHome),
    );
  }

  Widget _buildHome(BuildContext context) {
    return HomeScreen(
      onSearch: _openProcessing,
      onHistory: (homeContext) => Navigator.of(homeContext).push(
        MaterialPageRoute<void>(
          builder: (historyContext) => HistoryScreen(
            store: historyStore,
            onEntrySelected: (entry) =>
                _openHistoryEntry(historyContext, entry),
          ),
        ),
      ),
      onChat: (homeContext) => Navigator.of(homeContext).push(
        MaterialPageRoute<void>(
          builder: (_) => XaiChatbotScreen(
            conversation: CaseConversation.empty(
              service: retrievalService,
              followUp: followUp,
            ),
          ),
        ),
      ),
      onMap: (homeContext) => Navigator.of(homeContext).push(
        MaterialPageRoute<void>(builder: (_) => const LegalServicesScreen()),
      ),
      onAbout: (homeContext) => Navigator.of(homeContext)
          .push(MaterialPageRoute<void>(builder: (_) => const AboutScreen())),
    );
  }

  Future<bool> _openProcessing(BuildContext context, String concern) async {
    return await Navigator.of(context).push<bool>(
          MaterialPageRoute<bool>(
            builder: (processingContext) {
              final processingNavigator = Navigator.of(processingContext);
              return ProcessingScreen(
                concern: concern,
                onProcessingComplete: () async {
                  final response = await retrievalService.matchConcern(concern);
                  if (!processingContext.mounted) {
                    return;
                  }
                  final entry = await historyStore.addSearch(concern, response);
                  if (!processingContext.mounted) return;

                  developer.log(
                    'Navigating to match results',
                    name: 'catol.navigation',
                  );
                  final conversation = CaseConversation.forResponse(
                    service: retrievalService,
                    narrative: concern,
                    response: response,
                    followUp: followUp,
                  );
                  try {
                    await processingNavigator.push<void>(
                      MaterialPageRoute<void>(
                        builder: (resultsContext) => MatchResultsScreen(
                          results: [
                            ...response.results,
                            ...response.otherCandidates,
                          ],
                          userConcern: concern,
                          retrievalWarning: response.warning,
                          emptyMessage: response.clarifyingQuestion,
                          onResultSelected: (result) => _openLawResult(
                            resultsContext,
                            result,
                            conversation,
                            entry,
                          ),
                        ),
                      ),
                    );
                    if (processingContext.mounted &&
                        processingNavigator.mounted) {
                      processingNavigator.pop(true);
                    }
                  } catch (error, stackTrace) {
                    developer.log(
                      'Navigation to match results failed (${error.runtimeType})',
                      name: 'catol.navigation',
                      stackTrace: stackTrace,
                    );
                    rethrow;
                  }
                },
              );
            },
          ),
        ) ??
        false;
  }

  Future<void> _openHistoryEntry(
    BuildContext context,
    HistoryEntry entry,
  ) async {
    final response = CatalystMatchResponse(
      results: entry.results.take(entry.topResultCount).toList(),
      otherCandidates: entry.results.skip(entry.topResultCount).toList(),
      originalQuery: entry.concern,
      processedQuery: entry.processedQuery,
      warning: entry.warning,
      clarifyingQuestion: entry.emptyMessage,
      analysis: analyzeQuery(entry.concern),
    );
    final conversation = CaseConversation.forResponse(
      service: retrievalService,
      narrative: entry.concern,
      response: response,
      followUp: followUp,
    );
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (resultsContext) => MatchResultsScreen(
          results: entry.results,
          userConcern: entry.concern,
          retrievalWarning: entry.warning,
          emptyMessage: entry.emptyMessage,
          onResultSelected: (result) =>
              _openLawResult(resultsContext, result, conversation, entry),
        ),
      ),
    );
  }

  void _openLawResult(
    BuildContext context,
    LawMatchResult result,
    CaseConversation conversation,
    HistoryEntry entry,
  ) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LawDetailsScreen(
          result: result,
          conversation: conversation,
          initialIsBookmarked: entry.isFavorite,
          onBookmarkSave: (favorite) async {
            await historyStore.setFavorite(entry.id, favorite);
            entry.isFavorite = favorite;
          },
        ),
      ),
    );
  }
}
