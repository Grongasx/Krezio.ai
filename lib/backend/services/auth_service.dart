import 'package:firebase_auth/firebase_auth.dart';

/// Thin wrapper around FirebaseAuth — translates Firebase's error codes into
/// the friendly, Portuguese messages the rest of the app shows the user.
class AuthService {
  final FirebaseAuth _auth;

  AuthService({FirebaseAuth? auth}) : _auth = auth ?? FirebaseAuth.instance;

  User? get currentUser => _auth.currentUser;
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  Future<void> signUp({required String email, required String password, String? displayName}) async {
    try {
      final credential = await _auth.createUserWithEmailAndPassword(email: email, password: password);
      if (displayName != null && displayName.trim().isNotEmpty) {
        await credential.user?.updateDisplayName(displayName.trim());
      }
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(friendlyMessage(e.code));
    }
  }

  Future<void> signIn({required String email, required String password}) async {
    try {
      await _auth.signInWithEmailAndPassword(email: email, password: password);
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(friendlyMessage(e.code));
    }
  }

  /// The screen always answers "if the e-mail exists, we sent a link", so a
  /// stranger can't use this to find out who has an account: an unknown e-mail
  /// is treated as success. Real problems (no internet, too many tries) still fail.
  Future<void> sendPasswordResetEmail(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email);
    } on FirebaseAuthException catch (e) {
      if (e.code == 'user-not-found' || e.code == 'invalid-email') return;
      throw AuthFailure(friendlyMessage(e.code));
    }
  }

  Future<void> signOut() => _auth.signOut();

  /// Portuguese message for a FirebaseAuth error [code]. Never shows English.
  static String friendlyMessage(String code) {
    switch (code) {
      case 'invalid-email':
        return 'E-mail inválido.';
      case 'user-disabled':
        return 'Esta conta foi desativada.';
      case 'user-not-found':
        return 'Não encontramos uma conta com esse e-mail.';
      case 'wrong-password':
      case 'invalid-credential':
        return 'E-mail ou senha incorretos.';
      case 'email-already-in-use':
        return 'Esse e-mail já tem conta. Quer entrar?';
      case 'weak-password':
        return 'Senha fraca: use pelo menos 8 caracteres, com letras e números.';
      case 'network-request-failed':
        return 'Sem conexão com a internet. Tente novamente.';
      case 'too-many-requests':
        return 'Muitas tentativas. Aguarde um momento e tente de novo.';
      default:
        return 'Não foi possível completar a operação ($code).';
    }
  }
}

/// A user-facing authentication error with an already-translated message.
class AuthFailure implements Exception {
  final String message;
  const AuthFailure(this.message);

  @override
  String toString() => message;
}
