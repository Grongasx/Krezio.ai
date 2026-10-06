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
      throw AuthFailure(_friendlyMessage(e));
    }
  }

  Future<void> signIn({required String email, required String password}) async {
    try {
      await _auth.signInWithEmailAndPassword(email: email, password: password);
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(_friendlyMessage(e));
    }
  }

  Future<void> sendPasswordResetEmail(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email);
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(_friendlyMessage(e));
    }
  }

  Future<void> signOut() => _auth.signOut();

  String _friendlyMessage(FirebaseAuthException e) {
    switch (e.code) {
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
        return 'Já existe uma conta com esse e-mail.';
      case 'weak-password':
        return 'A senha precisa ter pelo menos 6 caracteres.';
      case 'network-request-failed':
        return 'Sem conexão com a internet. Tente novamente.';
      case 'too-many-requests':
        return 'Muitas tentativas. Aguarde um momento e tente de novo.';
      default:
        return 'Não foi possível completar a operação (${e.code}).';
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
