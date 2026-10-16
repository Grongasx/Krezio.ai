/// The app's version — kept equal to `version:` in pubspec.yaml (a test
/// checks it). Sent with every feedback so a report says which build it is.
class AppVersion {
  AppVersion._();

  static const String name = '0.4.0';
  static const int build = 4;

  static String get label => 'v$name ($build)';
}
