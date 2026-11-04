import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'services/catalyst_local_retrieval_service.dart';

class ProcessingScreen extends StatefulWidget {
  const ProcessingScreen({
    super.key,
    this.concern = '',
    this.onProcessingComplete,
  });

  final String concern;
  final Future<void> Function()? onProcessingComplete;

  @override
  State<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends State<ProcessingScreen> {
  var _isProcessing = false;
  String? _errorMessage;

  static const _background = Color(0xFFF2FEFF);
  static const _navy = Color(0xFF1A307F);
  static const _purple = Color(0xFF8254F2);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runProcessing();
    });
  }

  Future<void> _runProcessing() async {
    final onProcessingComplete = widget.onProcessingComplete;
    if (!mounted || onProcessingComplete == null || _isProcessing) {
      return;
    }

    setState(() {
      _isProcessing = true;
      _errorMessage = null;
    });
    developer.log('Processing started', name: 'catol.processing');
    try {
      await onProcessingComplete();
    } on CatalystRetrievalException catch (error) {
      developer.log(
        'Processing failed: ${error.failure.name}',
        name: 'catol.processing',
      );
      if (mounted) {
        setState(() {
          _errorMessage = error.message;
        });
      }
    } catch (error, stackTrace) {
      developer.log(
        'Processing failed with an unexpected error (${error.runtimeType})',
        name: 'catol.processing',
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() {
          _errorMessage =
              'An unexpected error occurred while retrieving matches. '
              'Please try again.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _background,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Column(
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    math.min(constraints.maxWidth * 0.05, 20),
                    18,
                    24,
                    8,
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () {
                          if (Navigator.of(context).canPop()) {
                            Navigator.of(context).pop();
                          }
                        },
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                          width: 28,
                          height: 28,
                        ),
                        icon: const Icon(
                          Icons.chevron_left_rounded,
                          color: _purple,
                          size: 28,
                        ),
                        tooltip: 'Back',
                      ),
                      const SizedBox(width: 12),
                      const Text(
                        'Processing',
                        style: TextStyle(
                          fontFamily: 'Montserrat',
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                          height: 1.2,
                          color: _navy,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, contentConstraints) {
                      final graphicSize = math.min(
                        math.min(
                          contentConstraints.maxWidth * 0.68,
                          contentConstraints.maxHeight * 0.4,
                        ),
                        276.0,
                      );

                      return Column(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _ProcessingGraphic(size: graphicSize),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: Column(
                              children: [
                                Text(
                                  _errorMessage == null
                                      ? 'Analyzing your case...'
                                      : 'Unable to retrieve matches',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontFamily: 'Montserrat',
                                    fontSize: 20,
                                    fontWeight: FontWeight.w600,
                                    height: 1.25,
                                    color: _navy,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                ConstrainedBox(
                                  constraints: BoxConstraints(
                                    maxWidth: contentConstraints.maxWidth * 0.9,
                                  ),
                                  child: Text(
                                    _errorMessage ??
                                        "We're extracting key legal concepts and matching\n"
                                            'relevant laws.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontFamily: 'Inter',
                                      fontSize: 14,
                                      height: 1.35,
                                      color: _navy,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Transform.translate(
                            offset: const Offset(0, -8),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Center(child: _ProcessingChecklist()),
                                if (_errorMessage != null) ...[
                                  const SizedBox(height: 16),
                                  FilledButton(
                                    onPressed: _isProcessing
                                        ? null
                                        : _runProcessing,
                                    child: const Text('Retry'),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ProcessingGraphic extends StatefulWidget {
  const _ProcessingGraphic({required this.size});

  final double size;

  @override
  State<_ProcessingGraphic> createState() => _ProcessingGraphicState();
}

class _ProcessingGraphicState extends State<_ProcessingGraphic>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _middleOpacity;
  late final Animation<double> _outerOpacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
    _middleOpacity = TweenSequence<double>([
      TweenSequenceItem(tween: ConstantTween(0.0), weight: 20),
      TweenSequenceItem(
        tween: Tween(
          begin: 0.0,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeInOut)),
        weight: 20,
      ),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 20),
      TweenSequenceItem(
        tween: Tween(
          begin: 1.0,
          end: 0.0,
        ).chain(CurveTween(curve: Curves.easeInOut)),
        weight: 20,
      ),
      TweenSequenceItem(tween: ConstantTween(0.0), weight: 20),
    ]).animate(_controller);
    _outerOpacity = TweenSequence<double>([
      TweenSequenceItem(tween: ConstantTween(0.0), weight: 45),
      TweenSequenceItem(
        tween: Tween(
          begin: 0.0,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeInOut)),
        weight: 20,
      ),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 20),
      TweenSequenceItem(
        tween: Tween(
          begin: 1.0,
          end: 0.0,
        ).chain(CurveTween(curve: Curves.easeInOut)),
        weight: 15,
      ),
    ]).animate(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          FadeTransition(
            opacity: _outerOpacity,
            child: Container(
              width: widget.size,
              height: widget.size,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFFF0F8FB),
              ),
            ),
          ),
          FadeTransition(
            opacity: _middleOpacity,
            child: Container(
              width: widget.size * 0.78,
              height: widget.size * 0.78,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFFEAF0FC),
              ),
            ),
          ),
          Container(
            width: widget.size * 0.54,
            height: widget.size * 0.54,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFFDEDEFC),
            ),
          ),
          SizedBox.square(
            dimension: widget.size * 0.34,
            child: const CustomPaint(
              painter: _SearchDocumentPainter(color: Color(0xFF8254F2)),
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchDocumentPainter extends CustomPainter {
  const _SearchDocumentPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.min(size.width, size.height) / 100;
    canvas
      ..save()
      ..translate(
        (size.width - 100 * scale) / 2,
        (size.height - 100 * scale) / 2,
      )
      ..scale(scale);

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final document = Path()
      ..moveTo(25, 12)
      ..lineTo(59, 12)
      ..lineTo(73, 26)
      ..lineTo(73, 48)
      ..moveTo(25, 12)
      ..lineTo(25, 82)
      ..lineTo(55, 82)
      ..moveTo(59, 12)
      ..lineTo(59, 26)
      ..lineTo(73, 26);
    canvas.drawPath(document, stroke);

    for (final y in [42.0, 53.0, 64.0]) {
      canvas.drawLine(Offset(34, y), Offset(53, y), stroke);
    }

    final magnifier = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5.5;
    canvas.drawCircle(const Offset(71, 65), 12, magnifier);
    canvas.drawLine(
      const Offset(80, 74),
      const Offset(93, 87),
      stroke
        ..strokeWidth = 8
        ..strokeCap = StrokeCap.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _SearchDocumentPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _ProcessingChecklist extends StatefulWidget {
  const _ProcessingChecklist();

  static const stages = [
    'Detecting language (English/Tagalog)',
    'Extracting legal concepts',
    'Finding relevant laws',
    'Generating results...',
  ];

  @override
  State<_ProcessingChecklist> createState() => _ProcessingChecklistState();
}

class _ProcessingChecklistState extends State<_ProcessingChecklist> {
  var _completedStages = 0;
  Timer? _progressTimer;

  @override
  void initState() {
    super.initState();
    _progressTimer = Timer.periodic(const Duration(milliseconds: 1500), (
      timer,
    ) {
      setState(() {
        _completedStages++;
      });
      if (_completedStages == _ProcessingChecklist.stages.length) {
        timer.cancel();
      }
    });
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SizedBox(
          width: math.min(constraints.maxWidth * 0.9, 288),
          child: Column(
            children: [
              for (
                var index = 0;
                index < _ProcessingChecklist.stages.length;
                index++
              ) ...[
                if (index > 0) const SizedBox(height: 18),
                Row(
                  children: [
                    if (index < _completedStages)
                      Container(
                        width: 24,
                        height: 24,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Color(0xFF3E86F8),
                        ),
                        child: const Icon(
                          Icons.check_rounded,
                          size: 18,
                          color: Colors.white,
                        ),
                      )
                    else if (index == _completedStages &&
                        index < _ProcessingChecklist.stages.length)
                      Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: const Color(0xFF3E86F8),
                            width: 2,
                          ),
                        ),
                        child: Center(
                          child: Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Color(0xFF3E86F8),
                            ),
                          ),
                        ),
                      )
                    else
                      Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: const Color(0xFFD4E1F4)),
                        ),
                      ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _ProcessingChecklist.stages[index],
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 13,
                          height: 1.25,
                          fontWeight: index == _completedStages
                              ? FontWeight.w600
                              : FontWeight.normal,
                          color: const Color(0xFF1A307F),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
