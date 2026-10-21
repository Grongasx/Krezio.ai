import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme/krezio_theme.dart';

/// Terms of use and privacy policy, bundled with the app (assets/legal).
class LegalDocuments {
  LegalDocuments._();

  /// Bump when either text changes: the user is asked to accept again.
  static const String version = '1.0';
  static const String termsAsset = 'assets/legal/termos_de_uso.md';
  static const String privacyAsset = 'assets/legal/politica_de_privacidade.md';

  /// Preference holding "version|ISO date" of the accepted documents.
  static const String acceptedPref = 'legal_accepted';

  static String acceptedValue(DateTime when) => '$version|${when.toIso8601String()}';

  /// Whether [stored] (from [acceptedPref]) accepts the current version.
  static bool isCurrent(String? stored) => stored != null && stored.split('|').first == version;

  static void open(BuildContext context, {required String title, required String asset}) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => LegalDocumentScreen(title: title, asset: asset)));
  }
}

/// Shows a bundled Markdown document as simple formatted text.
class LegalDocumentScreen extends StatelessWidget {
  final String title;
  final String asset;

  const LegalDocumentScreen({super.key, required this.title, required this.asset});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: FutureBuilder<String>(
        future: rootBundle.loadString(asset),
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          return ListView(
            padding: const EdgeInsets.all(KrezioSpace.lg),
            children: [for (final line in snap.data!.split('\n')) _line(context, line)],
          );
        },
      ),
    );
  }

  /// Minimal Markdown: headings, bullets and **bold**.
  static Widget _line(BuildContext context, String line) {
    final t = line.trimRight();
    if (t.isEmpty) return const SizedBox(height: KrezioSpace.sm);
    if (t.startsWith('# ')) {
      return Padding(
        padding: const EdgeInsets.only(bottom: KrezioSpace.sm),
        child: Text(t.substring(2), style: const TextStyle(fontSize: KrezioFont.headline, fontWeight: FontWeight.bold)),
      );
    }
    if (t.startsWith('## ')) {
      return Padding(
        padding: const EdgeInsets.only(top: KrezioSpace.md, bottom: KrezioSpace.xs),
        child: Text(t.substring(3), style: const TextStyle(fontSize: KrezioFont.title, fontWeight: FontWeight.bold)),
      );
    }
    final bullet = t.startsWith('- ');
    final body = bullet ? t.substring(2) : t;
    final spans = <TextSpan>[];
    final parts = body.split('**');
    for (var i = 0; i < parts.length; i++) {
      spans.add(TextSpan(text: parts[i], style: i.isOdd ? const TextStyle(fontWeight: FontWeight.bold) : null));
    }
    final text = Text.rich(TextSpan(children: spans), style: const TextStyle(fontSize: KrezioFont.body, height: 1.4));
    if (!bullet) return text;
    return Padding(
      padding: const EdgeInsets.only(left: KrezioSpace.sm),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('•  '), Expanded(child: text)]),
    );
  }
}
