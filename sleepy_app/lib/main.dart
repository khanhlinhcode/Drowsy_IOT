import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/sleep_provider.dart';
import 'screens/analytics_screen.dart';
import 'screens/home_screen.dart';
import 'services/auth_service.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  String? firebaseInitError;
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    if (kDebugMode) {
      debugPrint('[Firebase] initializeApp() success');
    }
  } catch (e) {
    firebaseInitError = e.toString();
    if (kDebugMode) {
      debugPrint('[Firebase] initializeApp() failed: $firebaseInitError');
    }
  }

  runApp(DrowsyApp(firebaseInitError: firebaseInitError));
}

class DrowsyApp extends StatelessWidget {
  const DrowsyApp({super.key, this.firebaseInitError});

  final String? firebaseInitError;

  @override
  Widget build(BuildContext context) {
    final theme = _buildTheme();

    if (firebaseInitError != null) {
      return MaterialApp(
        title: 'Drowsy Monitor',
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: _StartupErrorScreen(message: firebaseInitError!),
      );
    }

    // Lazy singleton access occurs only after Firebase init has completed.
    final authService = AuthService.instance;

    return StreamBuilder<User?>(
      stream: authService.authStateChanges,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return MaterialApp(
            title: 'Drowsy Monitor',
            debugShowCheckedModeBanner: false,
            theme: theme,
            home: const _BootScreen(),
          );
        }

        if (snapshot.hasError) {
          return MaterialApp(
            title: 'Drowsy Monitor',
            debugShowCheckedModeBanner: false,
            theme: theme,
            home: _StartupErrorScreen(
              message: 'Authentication stream failed: ${snapshot.error}',
            ),
          );
        }

        final user = snapshot.data;
        if (user == null) {
          return MaterialApp(
            title: 'Drowsy Monitor',
            debugShowCheckedModeBanner: false,
            theme: theme,
            home: _LoginScreen(authService: authService),
          );
        }

        return ChangeNotifierProvider<SleepProvider>(
          key: ValueKey<String>('sleep_provider_${user.uid}'),
          create: (_) => SleepProvider(userId: user.uid)..initialize(),
          child: MaterialApp(
            title: 'Drowsy Monitor',
            debugShowCheckedModeBanner: false,
            theme: theme,
            routes: <String, WidgetBuilder>{
              '/analytics': (_) => const AnalyticsScreen(),
            },
            home: const HomeScreen(),
          ),
        );
      },
    );
  }

  ThemeData _buildTheme() {
    return ThemeData(
      useMaterial3: true,
      platform: TargetPlatform.iOS,
      fontFamily: '.SF Pro Display',
      scaffoldBackgroundColor: Colors.transparent,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF3BA7F5),
        brightness: Brightness.dark,
      ),
      textTheme: const TextTheme(
        displayLarge: TextStyle(fontSize: 56, fontWeight: FontWeight.w700),
        displayMedium: TextStyle(fontSize: 44, fontWeight: FontWeight.w700),
        displaySmall: TextStyle(fontSize: 34, fontWeight: FontWeight.w700),
        headlineSmall: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
        titleLarge: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        titleMedium: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        bodyLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
        bodyMedium: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        bodySmall: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
      ),
    );
  }
}

class _BootScreen extends StatelessWidget {
  const _BootScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

class _StartupErrorScreen extends StatelessWidget {
  const _StartupErrorScreen({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Firebase initialization failed.\n\n$message',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ),
      ),
    );
  }
}

class _LoginScreen extends StatefulWidget {
  const _LoginScreen({required this.authService});

  final AuthService authService;

  @override
  State<_LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<_LoginScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool _createAccount = false;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final form = _formKey.currentState;
    if (form == null || !form.validate()) {
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      if (_createAccount) {
        await widget.authService.signUp(
          email: _emailController.text,
          password: _passwordController.text,
        );
      } else {
        await widget.authService.signIn(
          email: _emailController.text,
          password: _passwordController.text,
        );
      }
    } on AuthFailure catch (e) {
      setState(() {
        _error = e.message;
      });
    } catch (_) {
      setState(() {
        _error = 'Unexpected error. Please try again.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _submitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[
              Color(0xFF0D2435),
              Color(0xFF162C46),
              Color(0xFF203A57),
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Card(
                  color: Colors.white.withValues(alpha: 0.10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                    side: BorderSide(
                      color: Colors.white.withValues(alpha: 0.30),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          Text(
                            _createAccount ? 'Create Account' : 'Sign In',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Login is required to access realtime monitoring.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: Colors.white70),
                          ),
                          const SizedBox(height: 18),
                          TextFormField(
                            controller: _emailController,
                            keyboardType: TextInputType.emailAddress,
                            autofillHints: const <String>[AutofillHints.email],
                            decoration: const InputDecoration(
                              labelText: 'Email',
                              border: OutlineInputBorder(),
                            ),
                            validator: (value) {
                              final text = value?.trim() ?? '';
                              if (text.isEmpty) {
                                return 'Email is required.';
                              }
                              if (!text.contains('@')) {
                                return 'Enter a valid email.';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _passwordController,
                            obscureText: true,
                            autofillHints: const <String>[
                              AutofillHints.password,
                            ],
                            decoration: const InputDecoration(
                              labelText: 'Password',
                              border: OutlineInputBorder(),
                            ),
                            validator: (value) {
                              final text = value ?? '';
                              if (text.length < 6) {
                                return 'Password must be at least 6 characters.';
                              }
                              return null;
                            },
                          ),
                          if (_error != null) ...<Widget>[
                            const SizedBox(height: 10),
                            Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: const Color(0xFFFFD1D1)),
                            ),
                          ],
                          const SizedBox(height: 16),
                          FilledButton(
                            onPressed: _submitting ? null : _submit,
                            child: _submitting
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Text(
                                    _createAccount
                                        ? 'Create Account'
                                        : 'Sign In',
                                  ),
                          ),
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: _submitting
                                ? null
                                : () {
                                    setState(() {
                                      _createAccount = !_createAccount;
                                      _error = null;
                                    });
                                  },
                            child: Text(
                              _createAccount
                                  ? 'Have an account? Sign in'
                                  : 'Need an account? Create one',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
