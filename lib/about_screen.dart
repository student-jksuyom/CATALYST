import 'package:flutter/material.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static const _background = Color(0xFFF2FEFF);
  static const _navy = Color(0xFF1A307F);
  static const _blue = Color(0xFF3E86F8);
  static const _purple = Color(0xFF8254F2);
  static const _muted = Color(0xFFA6A6A6);
  static const _outline = Color(0xFFC4D4EB);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _background,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final horizontalInset = (constraints.maxWidth * 0.05)
                .clamp(16.0, 24.0)
                .toDouble();

            return ListView(
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 20),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _buildHeader(context),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: horizontalInset),
                  child: Image.asset(
                    'assets/images/catalyst_header.png',
                    fit: BoxFit.contain,
                    semanticLabel: 'CATALYST case-to-law system',
                  ),
                ),
                const SizedBox(height: 33),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: horizontalInset),
                  child: const _InformationCard(
                    heading: [
                      _HeadingPart('YOUR ', _navy),
                      _HeadingPart('LEGAL SUPPORT SYSTEM', _blue),
                    ],
                    content: _Description(),
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: horizontalInset),
                  child: const _InformationCard(
                    heading: [
                      _HeadingPart('SUPPORTED ', _navy),
                      _HeadingPart('LEGAL SOURCES', _blue),
                    ],
                    content: _LegalSources(),
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: horizontalInset),
                  child: const _InformationCard(
                    heading: [
                      _HeadingPart('IMPORTANT ', _navy),
                      _HeadingPart('NOTICE', _blue),
                    ],
                    content: _ImportantNotice(),
                  ),
                ),
                const SizedBox(height: 14),
                const _AppIdentification(),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          IconButton(
            onPressed: () {
              if (Navigator.of(context).canPop()) {
                Navigator.of(context).pop();
              }
            },
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 48, height: 48),
            icon: const Icon(
              Icons.chevron_left_rounded,
              color: _purple,
              size: 30,
            ),
            tooltip: 'Back',
          ),
          const SizedBox(width: 2),
          const Text(
            'About',
            style: TextStyle(
              fontFamily: 'Montserrat',
              fontSize: 27,
              fontWeight: FontWeight.w600,
              height: 1.2,
              color: _navy,
            ),
          ),
        ],
      ),
    );
  }
}

class _HeadingPart {
  const _HeadingPart(this.text, this.color);

  final String text;
  final Color color;
}

class _InformationCard extends StatelessWidget {
  const _InformationCard({required this.heading, required this.content});

  final List<_HeadingPart> heading;
  final Widget content;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 15, 20, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: AboutScreen._outline),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              children: [
                for (final part in heading)
                  TextSpan(
                    text: part.text,
                    style: TextStyle(color: part.color),
                  ),
              ],
            ),
            style: const TextStyle(
              fontFamily: 'Fredoka',
              fontSize: 23,
              fontWeight: FontWeight.w700,
              height: 1.22,
              letterSpacing: -0.35,
            ),
          ),
          const SizedBox(height: 8),
          content,
        ],
      ),
    );
  }
}

class _Description extends StatelessWidget {
  const _Description();

  @override
  Widget build(BuildContext context) {
    return const Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: 'CATALYST',
            style: TextStyle(color: AboutScreen._purple),
          ),
          TextSpan(
            text:
                ' is a case-to-law matching system designed to help users '
                'identify Philippine laws that may be relevant to their legal '
                'concerns.',
            style: TextStyle(color: AboutScreen._navy),
          ),
        ],
      ),
      style: TextStyle(
        fontFamily: 'Roboto',
        fontWeight: FontWeight.w400,
        fontSize: 14.5,
        height: 1.9,
      ),
    );
  }
}

class _LegalSources extends StatelessWidget {
  const _LegalSources();

  @override
  Widget build(BuildContext context) {
    const sources = [
      'Civil Code of the Philippines',
      'Family Code of the Philippines',
      'Consumer Act of the Philippines',
    ];

    return Padding(
      padding: const EdgeInsets.only(left: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var index = 0; index < sources.length; index++) ...[
            if (index > 0) const SizedBox(height: 3),
            Text(
              sources[index],
              style: const TextStyle(
                fontFamily: 'Roboto',
                fontWeight: FontWeight.w400,
                fontSize: 14.5,
                height: 1.7,
                color: AboutScreen._navy,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ImportantNotice extends StatelessWidget {
  const _ImportantNotice();

  @override
  Widget build(BuildContext context) {
    return const Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: 'CATALYST is designed to ',
            style: TextStyle(color: AboutScreen._navy),
          ),
          TextSpan(
            text: 'assist users in understanding potentially applicable laws.',
            style: TextStyle(color: AboutScreen._blue),
          ),
          TextSpan(
            text: ' It does ',
            style: TextStyle(color: AboutScreen._navy),
          ),
          TextSpan(
            text: 'not replace professional legal advice,',
            style: TextStyle(color: AboutScreen._blue),
          ),
          TextSpan(
            text:
                ' legal representation, or the judgment of a qualified legal '
                'practitioner.',
            style: TextStyle(color: AboutScreen._navy),
          ),
        ],
      ),
      style: TextStyle(
        fontFamily: 'Roboto',
        fontWeight: FontWeight.w400,
        fontSize: 14,
        height: 1.9,
      ),
    );
  }
}

class _AppIdentification extends StatelessWidget {
  const _AppIdentification();

  @override
  Widget build(BuildContext context) {
    return const Column(
      children: [
        Text(
          'CATALYST v1.0',
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 8,
            height: 1.4,
            color: AboutScreen._muted,
          ),
        ),
        Text(
          'Case-to-Law Matching System',
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 8,
            height: 1.4,
            color: AboutScreen._muted,
          ),
        ),
      ],
    );
  }
}
