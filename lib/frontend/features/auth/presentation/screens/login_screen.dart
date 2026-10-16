import 'package:flutter/material.dart';
import '../../../legal/legal_documents.dart';
import '../../../../theme/krezio_theme.dart';
import '../../../../../backend/services/auth_service.dart';
import '../../../../../backend/services/auth_validators.dart';

/// Email/password sign-in and sign-up. Krezio.ai's financial data stays
/// on-device either way — this screen only decides *whose* device data it is,
/// so it can be backed up and synced to the same account elsewhere.
class LoginScreen extends StatefulWidget {
  final AuthService authService;
  final bool isDark;

  /// Called once an account is created (the terms were accepted).
  final VoidCallback? onTermsAccepted;

  const LoginScreen({super.key, required this.authService, required this.isDark, this.onTermsAccepted});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();
  final _confirmController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _isSignUp = false;
  bool _acceptedTerms = false;
  bool _isLoading = false;
  bool _showPassword = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    // The submit button only turns on once every field is valid.
    for (final c in [_emailController, _passwordController, _confirmController]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  String? _passwordRule(String? v) => _isSignUp ? AuthValidators.newPassword(v) : AuthValidators.loginPassword(v);

  bool get _canSubmit =>
      AuthValidators.email(_emailController.text) == null &&
      _passwordRule(_passwordController.text) == null &&
      (!_isSignUp ||
          (AuthValidators.confirmPassword(_confirmController.text, _passwordController.text) == null && _acceptedTerms));

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      if (_isSignUp) {
        await widget.authService.signUp(
          email: _emailController.text.trim(),
          password: _passwordController.text,
          displayName: _nameController.text,
        );
        widget.onTermsAccepted?.call();
      } else {
        await widget.authService.signIn(
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );
      }
      // On success, the app's authStateChanges listener (in main.dart) takes
      // over and swaps this screen out — nothing more to do here.
    } on AuthFailure catch (e) {
      if (mounted) setState(() => _errorMessage = e.message);
    } catch (e) {
      if (mounted) setState(() => _errorMessage = 'Algo deu errado. Tente novamente.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _forgotPassword() async {
    final email = _emailController.text.trim();
    final invalid = AuthValidators.email(email);
    if (invalid != null) {
      setState(() => _errorMessage = 'Digite seu e-mail acima primeiro.');
      return;
    }
    try {
      await widget.authService.sendPasswordResetEmail(email);
      if (mounted) {
        // Same answer whether or not the account exists (see AuthService).
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Se o e-mail tiver conta, enviamos um link para redefinir a senha.')),
        );
      }
    } on AuthFailure catch (e) {
      setState(() => _errorMessage = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final bgColor = isDark ? KrezioColors.darkBackground : KrezioColors.lightBackground;
    final surfaceColor = isDark ? KrezioColors.darkSurface : KrezioColors.lightSurface;
    final primaryText = isDark ? KrezioColors.darkPrimaryText : KrezioColors.lightPrimaryText;
    final secondaryText = isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText;
    final borderColor = isDark ? KrezioColors.darkBorder : KrezioColors.lightBorder;

    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(KrezioSpace.xxl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(KrezioSpace.lg),
                      decoration: BoxDecoration(
                        color: KrezioColors.aiPurple.withOpacity(0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.auto_awesome, color: KrezioColors.aiPurple, size: 36),
                    ),
                    const SizedBox(height: KrezioSpace.lg),
                    Center(
                      child: Text(
                        'Krezio.ai',
                        style: TextStyle(fontSize: KrezioFont.headline, fontWeight: FontWeight.bold, color: primaryText),
                      ),
                    ),
                    const SizedBox(height: KrezioSpace.xs),
                    Center(
                      child: Text(
                        _isSignUp ? 'Crie sua conta para sincronizar seus dados' : 'Entre para continuar',
                        style: TextStyle(fontSize: KrezioFont.bodySmall, color: secondaryText),
                      ),
                    ),
                    const SizedBox(height: KrezioSpace.xxxl),
                    if (_isSignUp) ...[
                      TextFormField(
                        controller: _nameController,
                        style: TextStyle(color: primaryText),
                        decoration: _inputDecoration('Nome', Icons.person_outline, surfaceColor, borderColor, secondaryText),
                      ),
                      const SizedBox(height: KrezioSpace.md),
                    ],
                    TextFormField(
                      controller: _emailController,
                      style: TextStyle(color: primaryText),
                      keyboardType: TextInputType.emailAddress,
                      decoration: _inputDecoration('E-mail', Icons.email_outlined, surfaceColor, borderColor, secondaryText),
                      validator: AuthValidators.email,
                    ),
                    const SizedBox(height: KrezioSpace.md),
                    TextFormField(
                      controller: _passwordController,
                      style: TextStyle(color: primaryText),
                      obscureText: !_showPassword,
                      decoration: _inputDecoration('Senha', Icons.lock_outline, surfaceColor, borderColor, secondaryText).copyWith(
                        helperText: _isSignUp ? 'Pelo menos 8 caracteres, com letras e números' : null,
                        suffixIcon: IconButton(
                          tooltip: _showPassword ? 'Ocultar senha' : 'Mostrar senha',
                          icon: Icon(_showPassword ? Icons.visibility_off_outlined : Icons.visibility_outlined, color: secondaryText),
                          onPressed: () => setState(() => _showPassword = !_showPassword),
                        ),
                      ),
                      validator: _passwordRule,
                    ),
                    if (_isSignUp) ...[
                      const SizedBox(height: KrezioSpace.md),
                      TextFormField(
                        controller: _confirmController,
                        style: TextStyle(color: primaryText),
                        obscureText: !_showPassword,
                        decoration: _inputDecoration('Repita a senha', Icons.lock_outline, surfaceColor, borderColor, secondaryText),
                        validator: (v) => AuthValidators.confirmPassword(v, _passwordController.text),
                      ),
                      const SizedBox(height: KrezioSpace.sm),
                      // Accepting the terms is required to create an account.
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _acceptedTerms,
                        activeColor: KrezioColors.aiPurple,
                        onChanged: (v) => setState(() => _acceptedTerms = v ?? false),
                        title: Wrap(children: [
                          Text('Li e aceito os ', style: TextStyle(color: primaryText, fontSize: KrezioFont.small)),
                          GestureDetector(
                            onTap: () => LegalDocuments.open(context, title: 'Termos de uso', asset: LegalDocuments.termsAsset),
                            child: const Text('Termos de uso',
                                style: TextStyle(color: KrezioColors.aiPurple, fontSize: KrezioFont.small, decoration: TextDecoration.underline)),
                          ),
                          Text(' e a ', style: TextStyle(color: primaryText, fontSize: KrezioFont.small)),
                          GestureDetector(
                            onTap: () => LegalDocuments.open(context, title: 'Política de privacidade', asset: LegalDocuments.privacyAsset),
                            child: const Text('Política de privacidade',
                                style: TextStyle(color: KrezioColors.aiPurple, fontSize: KrezioFont.small, decoration: TextDecoration.underline)),
                          ),
                        ]),
                      ),
                    ],
                    if (_errorMessage != null) ...[
                      const SizedBox(height: KrezioSpace.md),
                      Text(
                        _errorMessage!,
                        style: const TextStyle(color: KrezioColors.friendlyOrange, fontSize: KrezioFont.bodySmall),
                      ),
                    ],
                    const SizedBox(height: KrezioSpace.xxl),
                    ElevatedButton(
                      onPressed: (_isLoading || !_canSubmit) ? null : _submit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: KrezioColors.aiPurple,
                        padding: const EdgeInsets.symmetric(vertical: KrezioSpace.lg),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : Text(
                              _isSignUp ? 'Criar conta' : 'Entrar',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                            ),
                    ),
                    const SizedBox(height: KrezioSpace.md),
                    if (!_isSignUp)
                      TextButton(
                        onPressed: _isLoading ? null : _forgotPassword,
                        child: const Text('Esqueci minha senha', style: TextStyle(color: KrezioColors.aiPurple)),
                      ),
                    TextButton(
                      onPressed: _isLoading
                          ? null
                          : () => setState(() {
                                _isSignUp = !_isSignUp;
                                _errorMessage = null;
                                _confirmController.clear();
                              }),
                      child: Text(
                        _isSignUp ? 'Já tenho uma conta — Entrar' : 'Não tenho conta — Criar uma',
                        style: TextStyle(color: secondaryText),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(String label, IconData icon, Color fill, Color border, Color labelColor) {
    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(color: labelColor),
      prefixIcon: Icon(icon, color: labelColor, size: 20),
      filled: true,
      fillColor: fill,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: border)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: border)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: KrezioColors.aiPurple)),
    );
  }
}
