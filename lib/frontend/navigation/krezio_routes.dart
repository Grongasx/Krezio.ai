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
}
