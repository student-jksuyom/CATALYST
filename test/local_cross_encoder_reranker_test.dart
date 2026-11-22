import 'package:catol/services/local_cross_encoder_reranker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const runtimeChannel = MethodChannel('flutter_onnxruntime');
  var nextValueId = 0;
  var batchSize = 0;

  setUp(() {
    nextValueId = 0;
    batchSize = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(runtimeChannel, (call) async {
          final arguments = call.arguments as Map<Object?, Object?>?;
          switch (call.method) {
            case 'createOrtValue':
              final shape = (arguments!['shape'] as List<Object?>).cast<int>();
              batchSize = shape.first;
              return {
                'valueId': 'test-value-${nextValueId++}',
                'dataType': arguments['sourceType'],
                'shape': shape,
              };
            case 'runInference':
              return {
                'logits': [
                  'test-logits',
                  'float32',
                  [batchSize, 1],
                ],
              };
            case 'getOrtValueData':
              return {
                'data': [
                  for (var index = 0; index < batchSize; index++) index / 10,
                ],
              };
            case 'releaseOrtValue':
            case 'closeSession':
              return null;
            default:
              throw MissingPluginException('Unexpected method: ${call.method}');
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(runtimeChannel, null);
  });

  test('tokenizes candidates and batches ONNX tensor inference', () async {
    var sessionLoads = 0;
    final scorer = LocalCrossEncoderReranker(
      modelAssetPath: LocalCrossEncoderReranker.desktopModelAssetPath,
      sessionLoader: (modelAssetPath) async {
        sessionLoads++;
        expect(modelAssetPath, LocalCrossEncoderReranker.desktopModelAssetPath);
        return OrtSession.fromMap({
          'sessionId': 'test-session',
          'inputNames': ['input_ids', 'attention_mask'],
          'outputNames': ['logits'],
        });
      },
    );
    const candidates = [
      CrossEncoderCandidate(
        articleId: 'civilcode:1305',
        articleText: 'A contract is a meeting of minds between two persons.',
        hybridScore: 0.4,
      ),
      CrossEncoderCandidate(
        articleId: 'civilcode:1723',
        articleText: 'An engineer or contractor is liable for a collapse.',
        hybridScore: 0.4,
      ),
    ];
    final concurrentScores = await Future.wait([
      scorer.score('A contractor and I agreed to a written contract.', candidates),
      scorer.score('A contractor and I agreed to a written contract.', candidates),
    ]);

    expect(concurrentScores, [
      [0.0, 0.1],
      [0.0, 0.1],
    ]);
    expect(sessionLoads, 1);
  });

  test('selects the ARM64 model for mobile and AVX2 for desktop', () {
    expect(
      LocalCrossEncoderReranker.modelAssetForPlatform(TargetPlatform.android),
      LocalCrossEncoderReranker.androidModelAssetPath,
    );
    expect(
      LocalCrossEncoderReranker.modelAssetForPlatform(TargetPlatform.iOS),
      LocalCrossEncoderReranker.androidModelAssetPath,
    );
    expect(
      LocalCrossEncoderReranker.modelAssetForPlatform(TargetPlatform.windows),
      LocalCrossEncoderReranker.desktopModelAssetPath,
    );
  });
}
