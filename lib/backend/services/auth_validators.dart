/// Form rules for login and sign-up, in pure Dart so they're testable without
/// Firebase. Each validator returns a Portuguese message, or null when valid.
class AuthValidators {
  AuthValidators._();

  static final RegExp _email = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$');

  static String? email(String? value) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return 'Digite seu e-mail';
    if (!_email.hasMatch(v)) return 'E-mail inválido';
    return null;
  }

  /// Login only checks that a password was typed — the strength rule applies
  /// to new accounts, not to people who already have one.
  static String? loginPassword(String? value) => (value == null || value.isEmpty) ? 'Digite sua senha' : null;

  /// New password: 8+ characters with at least one letter and one number.
  static String? newPassword(String? value) {
    final v = value ?? '';
    if (v.isEmpty) return 'Crie uma senha';
    if (v.length < 8) return 'Use pelo menos 8 caracteres';
    if (!RegExp(r'[A-Za-zÀ-ÿ]').hasMatch(v) || !RegExp(r'\d').hasMatch(v)) {
      return 'Use letras e números';
    }
    return null;
  }

  static String? confirmPassword(String? value, String password) {
    if (value == null || value.isEmpty) return 'Repita a senha';
    if (value != password) return 'As senhas não são iguais';
    return null;
  }

  static String? termsAccepted(bool accepted) =>
      accepted ? null : 'Para criar a conta, aceite os Termos de uso e a Política de privacidade';
}
