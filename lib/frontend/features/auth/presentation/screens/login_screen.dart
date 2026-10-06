import 'package:flutter/material.dart';
import '../../../../theme/krezio_theme.dart';
import '../../../../../backend/services/auth_service.dart';

/// Email/password sign-in and sign-up. Krezio.ai's financial data stays
/// on-device either way — this screen only decides *whose* device data it is,
/// so it can be backed up and synced to the same account elsewhere.
class LoginScreen extends StatefulWidget {
  final AuthService authService;
  final bool isDark;

  const LoginScreen({super.key, required this.authService, required this.isDark});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _isSignUp = false;
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    super.dispose();
  }

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
    if (email.isEmpty) {
      setState(() => _errorMessage = 'Digite seu e-mail acima primeiro.');
      return;
    }
    try {
      await widget.authService.sendPasswordResetEmail(email);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enviamos um link de redefinição de senha para o seu e-mail.')),
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
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: KrezioColors.aiPurple.withOpacity(0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.auto_awesome, color: KrezioColors.aiPurple, size: 36),
                    ),
                    const SizedBox(height: 16),
                    Center(
                      child: Text(
                        'Krezio.ai',
                        style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: primaryText),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Center(
                      child: Text(
                        _isSignUp ? 'Crie sua conta para sincronizar seus dados' : 'Entre para continuar',
                        style: TextStyle(fontSize: 13, color: secondaryText),
                      ),
                    ),
                    const SizedBox(height: 32),
                    if (_isSignUp) ...[
                      TextFormField(
                        controller: _nameController,
                        style: TextStyle(color: primaryText),
                        decoration: _inputDecoration('Nome', Icons.person_outline, surfaceColor, borderColor, secondaryText),
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextFormField(
                      controller: _emailController,
                      style: TextStyle(color: primaryText),
                      keyboardType: TextInputType.emailAddress,
                      decoration: _inputDecoration('E-mail', Icons.email_outlined, surfaceColor, borderColor, secondaryText),
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) return 'Digite seu e-mail';
                        if (!v.contains('@') || !v.contains('.')) return 'E-mail inválido';
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _passwordController,
                      style: TextStyle(color: primaryText),
                      obscureText: true,
                      decoration: _inputDecoration('Senha', Icons.lock_outline, surfaceColor, borderColor, secondaryText),
                      validator: (v) {
                        if (v == null || v.isEmpty) return 'Digite sua senha';
                        if (v.length < 6) return 'A senha precisa ter pelo menos 6 caracteres';
                        return null;
                      },
                    ),
                    if (_errorMessage != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _errorMessage!,
                        style: const TextStyle(color: KrezioColors.friendlyOrange, fontSize: 13),
                      ),
                    ],
                    const SizedBox(height: 24),
                    ElevatedButton(
                      onPressed: _isLoading ? null : _submit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: KrezioColors.aiPurple,
                        padding: const EdgeInsets.symmetric(vertical: 14),
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
                    const SizedBox(height: 12),
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
