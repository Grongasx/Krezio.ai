import 'package:flutter/foundation.dart';

/// Named routes of the main tabs. Opening the app at one of them (web URL
/// `/#/chat`, Android route intent) lands on that tab, and switching tabs
/// updates the URL so a reload keeps the same tab.
class KrezioRoutes {
  static const String inicio = '/';
  static const String extrato = '/extrato';
  static const String chat = '/chat';
  static const String metas = '/metas';
  static const String ajustes = '/ajustes';

  /// Tab order of the bottom navigation bar.
  static const List<String> tabs = [inicio, extrato, chat, metas, ajustes];

  /// Tab index for [route]; unknown routes fall back to the home tab.
  static int tabFor(String? route) {
    final path = Uri.tryParse(route ?? '')?.path ?? '';
    final i = tabs.indexOf(path.isEmpty ? inicio : path);
    return i < 0 ? 0 : i;
  }

  /// "krezio://app/chat?frase=gastei 30 no uber" (shortcut, widget, voice
  /// assistant): the sentence to send to César, if any.
  static String? phraseIn(Uri? link) {
    final p = link?.queryParameters['frase']?.trim();
    return p == null || p.isEmpty ? null : p;
  }

  /// "…?voz=1": open the voice conversation.
  static bool wantsVoice(Uri? link) => link?.queryParameters['voz'] == '1';

  /// A link the app was opened with (or received while open), waiting to be
  /// handled: the navigation switches tab, the chat sends the sentence or
  /// opens the voice. Set back to null once handled.
  static final ValueNotifier<Uri?> pendingLink = ValueNotifier<Uri?>(null);

  /// Normalizes "krezio://app/chat?x" and "/chat?x" to a route Uri.
  static Uri? asRoute(Uri? link) {
    if (link == null) return null;
    final path = link.path.isEmpty ? inicio : link.path;
    return Uri(path: path, queryParameters: link.queryParameters.isEmpty ? null : link.queryParameters);
  }
}
