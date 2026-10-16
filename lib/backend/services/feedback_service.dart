import '../config/app_version.dart';
import '../repositories/financial_repository.dart';

/// "Isso ajudou?" on César's answers and "Fale com a gente". Only counts and
/// the app version are kept — never the text of the answer, which may carry
/// the user's financial data. Pure Dart.
class FeedbackService {
  static const _kYes = 'feedback_helpful_yes';
  static const _kNo = 'feedback_helpful_no';

  final FinancialRepository repository;
  FeedbackService(this.repository);

  int _count(String key) => int.tryParse(repository.preference(key) ?? '') ?? 0;

  int get helpful => _count(_kYes);
  int get notHelpful => _count(_kNo);

  /// One vote on an answer.
  void rateAnswer({required bool helpful}) {
    final key = helpful ? _kYes : _kNo;
    repository.setPreference(key, '${_count(key) + 1}');
  }

  /// The message sent by "Fale com a gente": the user's text, the version and
  /// the vote counts.
  String compose(String userText, {required String platform, DateTime? now}) {
    final when = (now ?? DateTime.now()).toIso8601String().substring(0, 16).replaceFirst('T', ' ');
    return '${userText.trim()}\n\n'
        '— Krezio.ai ${AppVersion.label} · $platform · $when\n'
        '— Respostas do César: $helpful ajudaram, $notHelpful não ajudaram';
  }
}
