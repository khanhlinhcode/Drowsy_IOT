import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

class AuthFailure implements Exception {
  AuthFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

class AuthService {
  AuthService._internal();

  static AuthService? _instance;

  static AuthService get instance => _instance ??= AuthService._internal();

  FirebaseAuth? _auth;

  FirebaseAuth get _firebaseAuth {
    if (Firebase.apps.isEmpty) {
      throw StateError(
        'Firebase is not initialized. Call Firebase.initializeApp() before AuthService usage.',
      );
    }
    return _auth ??= FirebaseAuth.instance;
  }

  Stream<User?> get authStateChanges => _firebaseAuth.authStateChanges();

  User? get currentUser => _firebaseAuth.currentUser;

  String? get currentUserId => _firebaseAuth.currentUser?.uid;

  Future<UserCredential> signIn({
    required String email,
    required String password,
  }) async {
    try {
      return await _firebaseAuth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(_mapAuthError(e));
    }
  }

  Future<UserCredential> signUp({
    required String email,
    required String password,
  }) async {
    try {
      return await _firebaseAuth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(_mapAuthError(e));
    }
  }

  Future<void> signOut() => _firebaseAuth.signOut();

  String _mapAuthError(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-email':
        return 'The email format is invalid.';
      case 'user-disabled':
        return 'This account is disabled.';
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return 'Incorrect email or password.';
      case 'email-already-in-use':
        return 'This email is already in use.';
      case 'weak-password':
        return 'Password is too weak (minimum 6 characters).';
      case 'too-many-requests':
        return 'Too many attempts. Please try again later.';
      case 'network-request-failed':
        return 'Network error. Check your connection and retry.';
      default:
        return e.message ?? 'Authentication failed. Please try again.';
    }
  }
}
