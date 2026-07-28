import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../config/dev_accounts.dart';
import '../../state/auth_state.dart';

/// Dernier email utilisé, pré-rempli au lancement suivant. L'email seul —
/// jamais le mot de passe, qui n'a rien à faire dans des préférences en clair.
const _lastEmailPrefsKey = 'echango_merchant_last_email';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _restoreLastEmail();
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _restoreLastEmail() async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getString(_lastEmailPrefsKey);
    if (last != null && mounted && _emailController.text.isEmpty) {
      setState(() => _emailController.text = last);
    }
  }

  Future<void> _rememberEmail(String email) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastEmailPrefsKey, email);
  }

  Future<void> _submit(AuthState authState, {DevAccount? account}) async {
    final email = account?.email ?? _emailController.text.trim();
    final password = account?.password ?? _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Renseigner l\'email et le mot de passe')),
      );
      return;
    }

    final router = GoRouter.of(context);
    final success = await authState.login(email: email, password: password);
    if (!mounted) return;
    if (success) {
      await _rememberEmail(email);
      router.go('/commandes');
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = context.watch<AuthState>();

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              // Garde une largeur lisible sur tablette et, plus tard, sur web.
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.storefront,
                      size: 64, color: Theme.of(context).primaryColor),
                  const SizedBox(height: 16),
                  Text(
                    'Echango Commerçant',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Commandez un transporteur et suivez vos livraisons',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.email_outlined),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _passwordController,
                    obscureText: true,
                    onSubmitted: (_) => _submit(authState),
                    decoration: const InputDecoration(
                      labelText: 'Mot de passe',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.lock_outlined),
                    ),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: authState.isLoading ? null : () => _submit(authState),
                    child: authState.isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Se connecter'),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => context.push('/register'),
                    child: const Text('Créer un compte commerçant'),
                  ),
                  if (authState.errorMessage != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        border: Border.all(color: Colors.red),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        authState.errorMessage!,
                        style: TextStyle(color: Colors.red.shade700),
                      ),
                    ),
                  ],
                  _buildDevAccounts(authState),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Comptes de test, debug uniquement et fournis au build — voir
  /// dev_accounts.dart. Invisible en release.
  Widget _buildDevAccounts(AuthState authState) {
    final accounts = DevAccounts.accounts;
    if (accounts.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        Text(
          'Comptes de test (debug)',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.grey[600],
              ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: accounts
              .map((a) => ActionChip(
                    avatar: const Icon(Icons.store_outlined, size: 18),
                    label: Text(a.label),
                    onPressed: authState.isLoading
                        ? null
                        : () => _submit(authState, account: a),
                  ))
              .toList(),
        ),
      ],
    );
  }
}
