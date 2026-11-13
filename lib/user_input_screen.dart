import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class UserInputScreen extends StatefulWidget {
  const UserInputScreen({required this.onProcess, super.key});

  final Future<bool> Function(
    BuildContext context,
    String mainProblem,
    String supportingContext,
  )
  onProcess;

  @override
  State<UserInputScreen> createState() => _UserInputScreenState();
}

class _UserInputScreenState extends State<UserInputScreen> {
  static const _navy = Color(0xFF1A307F);
  static const _purple = Color(0xFF8254F2);

  final _mainController = TextEditingController();
  final _contextController = TextEditingController();
  var _showRequiredError = false;
  var _isSubmitting = false;

  bool get _hasMainProblem => _mainController.text.trim().isNotEmpty;

  @override
  void dispose() {
    _mainController.dispose();
    _contextController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final mainProblem = _mainController.text.trim();
    if (mainProblem.isEmpty) {
      setState(() => _showRequiredError = true);
      await HapticFeedback.mediumImpact();
      return;
    }
    if (_isSubmitting) return;

    setState(() => _isSubmitting = true);
    try {
      final completed = await widget.onProcess(
        context,
        mainProblem,
        _contextController.text.trim(),
      );
      if (completed && mounted) {
        Navigator.of(context).pop(true);
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final horizontal = (MediaQuery.sizeOf(context).width * 0.095).clamp(
      24.0,
      38.0,
    );

    return Scaffold(
      backgroundColor: Colors.white,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 24, 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: _isSubmitting
                        ? null
                        : () => Navigator.of(context).maybePop(),
                    icon: const Icon(
                      Icons.chevron_left_rounded,
                      color: _purple,
                      size: 32,
                    ),
                    tooltip: 'Back',
                  ),
                  const SizedBox(width: 4),
                  const Expanded(
                    child: Text(
                      'Submit Concern',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Montserrat',
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                        color: _navy,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.fromLTRB(horizontal, 20, horizontal, 18),
                children: [
                  const Text(
                    'Tell us what happened (optional):',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 14,
                      color: _navy,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _NarrativeField(
                    key: const ValueKey('supporting-context-field'),
                    controller: _contextController,
                    hint: 'Add background facts that may help explain your concern.',
                    minLines: 5,
                    maxLines: 8,
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 24),
                  Text.rich(
                    TextSpan(
                      text: 'Your MAIN problem/concern is ',
                      style: const TextStyle(color: _navy),
                      children: const [
                        TextSpan(
                          text: '(required)',
                          style: TextStyle(color: _purple),
                        ),
                      ],
                    ),
                    style: const TextStyle(fontFamily: 'Inter', fontSize: 14),
                  ),
                  const SizedBox(height: 8),
                  _NarrativeField(
                    key: const ValueKey('main-problem-field'),
                    controller: _mainController,
                    hint: 'Describe the main legal problem you want help with.',
                    minLines: 3,
                    maxLines: 6,
                    hasError: _showRequiredError && !_hasMainProblem,
                    onChanged: (_) {
                      if (_showRequiredError && _hasMainProblem) {
                        setState(() => _showRequiredError = false);
                      } else {
                        setState(() {});
                      }
                    },
                  ),
                  if (_showRequiredError && !_hasMainProblem) ...[
                    const SizedBox(height: 6),
                    Semantics(
                      liveRegion: true,
                      child: const Text(
                        'Your main problem is required.',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 12,
                          color: Color(0xFFB3261E),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  const Text(
                    'You may write in English, Tagalog, or Taglish.',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 12,
                      color: Color(0xFF667085),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(horizontal, 8, horizontal, 20),
              child: SizedBox(
                width: double.infinity,
                height: 62,
                child: Semantics(
                  button: true,
                  label: 'Process concern',
                  hint: _hasMainProblem
                      ? 'Search for potentially relevant legal provisions'
                      : 'Enter your main problem first',
                  child: Opacity(
                    opacity: _hasMainProblem ? 1 : 0.48,
                    child: FilledButton.icon(
                      key: const ValueKey('process-concern-button'),
                      onPressed: _isSubmitting ? null : _submit,
                      style: FilledButton.styleFrom(
                        backgroundColor: _purple,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      icon: _isSubmitting
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.send_rounded, size: 24),
                      label: Text(
                        _isSubmitting ? 'Processing...' : 'Process Concern',
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.1,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NarrativeField extends StatelessWidget {
  const _NarrativeField({
    required this.controller,
    required this.hint,
    required this.minLines,
    required this.maxLines,
    required this.onChanged,
    this.hasError = false,
    super.key,
  });

  final TextEditingController controller;
  final String hint;
  final int minLines;
  final int maxLines;
  final bool hasError;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final borderColor = hasError
        ? const Color(0xFFB3261E)
        : const Color(0xFF1A307F);
    return AnimatedContainer(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        border: Border.all(color: borderColor, width: hasError ? 2.5 : 2),
        borderRadius: BorderRadius.circular(15),
        boxShadow: hasError
            ? [
                BoxShadow(
                  color: const Color(0xFFB3261E).withValues(alpha: 0.2),
                  blurRadius: 10,
                ),
              ]
            : const [],
      ),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        keyboardType: TextInputType.multiline,
        textInputAction: TextInputAction.newline,
        minLines: minLines,
        maxLines: maxLines,
        maxLength: 5000,
        textCapitalization: TextCapitalization.sentences,
        style: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 14,
          height: 1.45,
          color: _UserInputScreenState._navy,
        ),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(
            fontFamily: 'Inter',
            color: Color(0xFF9AA1AC),
          ),
          contentPadding: const EdgeInsets.all(14),
          counterStyle: const TextStyle(fontSize: 10),
          border: InputBorder.none,
          errorText: hasError ? 'Required' : null,
        ),
      ),
    );
  }
}
