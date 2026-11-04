import 'dart:math' as math;

import 'package:flutter/material.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.onSearch,
    this.onHistory,
    this.onChat,
    this.onAbout,
  });

  final Future<bool> Function(BuildContext context, String concern)? onSearch;
  final Future<void> Function(BuildContext context)? onHistory;
  final Future<void> Function(BuildContext context)? onChat;
  final Future<void> Function(BuildContext context)? onAbout;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _navy = Color(0xFF1A307F);
  static const _blue = Color(0xFF3E86F8);
  static const _purple = Color(0xFF3F2381);
  static const _scalesAsset = 'assets/images/catalyst_scales.png';
  static const _menuBackground = Color(0xFFF2FEFF);
  static const _menuPurple = Color(0xFF3F2381);

  final _concernController = TextEditingController();
  var _isMenuOpen = false;

  @override
  void dispose() {
    _concernController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, viewport) {
            final menuWidth = math.min(viewport.maxWidth * 0.72, 320.0);

            return Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    final horizontalPadding = (constraints.maxWidth * 0.085)
                        .clamp(32.0, 36.0);
                    final headerHeight = math.min(
                      44.0,
                      constraints.maxHeight * 0.06,
                    );

                    final content = Padding(
                      padding: EdgeInsets.fromLTRB(
                        0,
                        constraints.maxHeight * 0.028,
                        0,
                        constraints.maxHeight * 0.075,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 18),
                            child: SizedBox(
                              height: headerHeight,
                              child: Row(
                                children: [
                                  ColorFiltered(
                                    colorFilter: const ColorFilter.mode(
                                      _purple,
                                      BlendMode.srcIn,
                                    ),
                                    child: Image.asset(
                                      _scalesAsset,
                                      width: 43,
                                      height: headerHeight,
                                      fit: BoxFit.contain,
                                    ),
                                  ),
                                  const SizedBox(width: 9),
                                  const Text(
                                    'CATALYST',
                                    style: TextStyle(
                                      fontFamily: 'Fredoka',
                                      fontSize: 26,
                                      fontWeight: FontWeight.w600,
                                      height: 1,
                                      color: _navy,
                                    ),
                                  ),
                                  const Spacer(),
                                  IconButton(
                                    onPressed: () =>
                                        setState(() => _isMenuOpen = true),
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints.tightFor(
                                      width: 30,
                                      height: 44,
                                    ),
                                    icon: const Icon(
                                      Icons.menu_rounded,
                                      color: _navy,
                                      size: 30,
                                    ),
                                    tooltip: 'Open menu',
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Expanded(
                            child: SingleChildScrollView(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(
                                    height: constraints.maxHeight * 0.145,
                                  ),
                                  Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: horizontalPadding,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Text.rich(
                                          TextSpan(
                                            children: [
                                              TextSpan(
                                                text: 'Describe your\n',
                                                style: TextStyle(color: _navy),
                                              ),
                                              TextSpan(
                                                text: 'legal concern',
                                                style: TextStyle(color: _blue),
                                              ),
                                            ],
                                          ),
                                          style: TextStyle(
                                            fontFamily: 'Montserrat',
                                            fontSize: 32,
                                            fontWeight: FontWeight.w600,
                                            height: 1.35,
                                          ),
                                        ),
                                        const SizedBox(height: 5),
                                        const Text.rich(
                                          TextSpan(
                                            style: TextStyle(color: _navy),
                                            children: [
                                              TextSpan(
                                                text: 'Tell us what happened. You can type it in ',
                                              ),
                                              TextSpan(
                                                text: 'English',
                                                style: TextStyle(color: _blue),
                                              ),
                                              TextSpan(text: ',\n'),
                                              TextSpan(
                                                text: 'Tagalog',
                                                style: TextStyle(color: _blue),
                                              ),
                                              TextSpan(text: ', or a mix ('),
                                              TextSpan(
                                                text: 'Taglish',
                                                style: TextStyle(color: _blue),
                                              ),
                                              TextSpan(text: ').'),
                                            ],
                                          ),
                                          style: TextStyle(
                                            fontFamily: 'Inter',
                                            fontSize: 14,
                                            height: 1.35,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: horizontalPadding,
                            ),
                            child: _ConcernInput(
                              controller: _concernController,
                              onSearch: _submitConcern,
                            ),
                          ),
                        ],
                      ),
                    );
                    return content;
                  },
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: !_isMenuOpen,
                    child: GestureDetector(
                      onTap: _closeMenu,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 260),
                        color: _isMenuOpen
                            ? Colors.black.withValues(alpha: 0.28)
                            : Colors.transparent,
                      ),
                    ),
                  ),
                ),
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  top: 0,
                  bottom: 0,
                  right: _isMenuOpen ? 0 : -menuWidth,
                  width: menuWidth,
                  child: IgnorePointer(
                    ignoring: !_isMenuOpen,
                    child: ExcludeSemantics(
                      excluding: !_isMenuOpen,
                      child: _buildSideMenu(),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  void _closeMenu() {
    if (_isMenuOpen) setState(() => _isMenuOpen = false);
  }

  Future<void> _selectMenuItem(
    Future<void> Function(BuildContext context)? callback,
  ) async {
    _closeMenu();
    if (callback == null) return;
    await callback(context);
    if (mounted) _resetConcern();
  }

  Future<void> _submitConcern() async {
    final shouldReset =
        await widget.onSearch?.call(context, _concernController.text) ?? false;
    if (mounted && shouldReset) _resetConcern();
  }

  void _resetConcern() {
    _concernController.clear();
  }

  Widget _buildSideMenu() {
    return Container(
      decoration: const BoxDecoration(
        color: _menuBackground,
        border: Border(left: BorderSide(color: Color(0xFFC4D4EB))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 14, 16, 0),
            child: SizedBox(
              height: 52,
              child: Row(
                children: [
                  IconButton(
                    onPressed: _closeMenu,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 48,
                      height: 48,
                    ),
                    icon: const Icon(
                      Icons.menu_rounded,
                      color: _menuPurple,
                      size: 30,
                    ),
                    tooltip: 'Close menu',
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: FittedBox(
                      alignment: Alignment.centerLeft,
                      fit: BoxFit.scaleDown,
                      child: Text(
                        'CATALYST',
                        style: TextStyle(
                          fontFamily: 'Fredoka',
                          fontSize: 27,
                          fontWeight: FontWeight.w700,
                          color: _navy,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 27),
          _MenuItem(
            label: 'History',
            asset: 'assets/images/menu_history.png',
            onTap: () => _selectMenuItem(widget.onHistory),
          ),
          _MenuItem(
            label: 'Chat',
            asset: 'assets/images/menu_chat.png',
            onTap: () => _selectMenuItem(widget.onChat),
          ),
          _MenuItem(
            label: 'About',
            asset: 'assets/images/menu_about.png',
            onTap: () => _selectMenuItem(widget.onAbout),
          ),
        ],
      ),
    );
  }
}

class _ConcernInput extends StatelessWidget {
  const _ConcernInput({required this.controller, this.onSearch});

  final TextEditingController controller;
  final VoidCallback? onSearch;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('home-concern-composer'),
      constraints: const BoxConstraints(minHeight: 66, maxHeight: 122),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFD8D8D8)),
        borderRadius: BorderRadius.circular(36),
      ),
      padding: const EdgeInsets.fromLTRB(17, 8, 13, 8),
      child: Row(
        children: [
          ColorFiltered(
            colorFilter: const ColorFilter.mode(
              Color(0xFF737373),
              BlendMode.srcIn,
            ),
            child: Image.asset(
              'assets/images/catalyst_scales.png',
              width: 39,
              height: 36,
              fit: BoxFit.contain,
            ),
          ),
          const SizedBox(width: 9),
          const SizedBox(
            height: 30,
            child: VerticalDivider(
              width: 1,
              thickness: 1,
              color: Color(0xFFBDBDBD),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: TextField(
              controller: controller,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              minLines: 1,
              maxLines: 4,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 14,
                color: Color(0xFF737373),
              ),
              decoration: const InputDecoration(
                hintText: 'Type your concern here...',
                hintMaxLines: 1,
                hintStyle: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 14,
                  color: Color(0xFFA3A3A3),
                ),
                border: InputBorder.none,
                isCollapsed: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 44,
            height: 44,
            child: Material(
              color: const Color(0xFF8E63F5),
              shape: const CircleBorder(),
              child: IconButton(
                onPressed: onSearch,
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.search, size: 25, color: Colors.white),
                tooltip: 'Search',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuItem extends StatelessWidget {
  const _MenuItem({
    required this.label,
    required this.asset,
    required this.onTap,
  });

  final String label;
  final String asset;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 82,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              Image.asset(asset, width: 43, height: 50, fit: BoxFit.contain),
              const SizedBox(width: 16),
              Text(
                label,
                style: const TextStyle(
                  fontFamily: 'Roboto',
                  fontSize: 25,
                  fontWeight: FontWeight.w400,
                  color: Color(0xFF3F2381),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
