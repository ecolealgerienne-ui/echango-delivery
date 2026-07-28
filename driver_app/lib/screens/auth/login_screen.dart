import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../config/dev_accounts.dart';
import '../../state/auth_state.dart';

/// Dernier email utilisé, pour le pré-remplir au lancement suivant. Seul
/// l'email est conservé — jamais le mot de passe, qui n'a rien à faire dans
/// des préférences en clair.
const _lastEmailPrefsKey = 'echango_driver_last_email';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late PageController _pageController;
  int _currentPage = 0;
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _phoneController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _restoreLastEmail();
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

  /// Connexion en un tap depuis un compte de développement.
  Future<void> _loginAs(DevAccount account, AuthState authState) async {
    _emailController.text = account.email;
    _passwordController.text = account.password;

    final router = GoRouter.of(context);
    final success = await authState.loginWithEmail(
      email: account.email,
      password: account.password,
    );
    if (!mounted) return;
    if (success) {
      await _rememberEmail(account.email);
      router.go('/dashboard');
    }
  }

  /// Sélecteur de comptes de test. Vide (donc invisible) hors debug et si
  /// DEV_ACCOUNTS n'est pas fourni au build — voir dev_accounts.dart.
  Widget _buildDevAccountPicker(AuthState authState) {
    final accounts = DevAccounts.accounts;
    if (accounts.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        Row(
          children: [
            const Icon(Icons.science_outlined, size: 16, color: Colors.grey),
            const SizedBox(width: 6),
            Text(
              'Comptes de test (debug)',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey[600],
                  ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: accounts
              .map((a) => ActionChip(
                    avatar: const Icon(Icons.person_outline, size: 18),
                    label: Text(a.label),
                    onPressed:
                        authState.isLoading ? null : () => _loginAs(a, authState),
                  ))
              .toList(),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _phoneController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Login'),
        elevation: 0,
      ),
      body: PageView(
        controller: _pageController,
        onPageChanged: (index) {
          setState(() => _currentPage = index);
        },
        children: [
          _buildEmailLoginPage(context),
          _buildPhoneLoginPage(context),
        ],
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton(
              onPressed: _currentPage == 0
                  ? null
                  : () => _pageController.previousPage(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                      ),
              child: const Text('Email Login'),
            ),
            const SizedBox(width: 8),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _currentPage == 0
                    ? Theme.of(context).primaryColor
                    : Colors.grey,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _currentPage == 1
                    ? Theme.of(context).primaryColor
                    : Colors.grey,
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _currentPage == 1
                  ? null
                  : () => _pageController.nextPage(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                      ),
              child: const Text('Phone Login'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmailLoginPage(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 32),
          Icon(
            Icons.email,
            size: 64,
            color: Theme.of(context).primaryColor,
          ),
          const SizedBox(height: 24),
          Text(
            'Login with Email',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 32),
          TextField(
            controller: _emailController,
            decoration: InputDecoration(
              labelText: 'Email',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              prefixIcon: const Icon(Icons.email_outlined),
            ),
            keyboardType: TextInputType.emailAddress,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _passwordController,
            decoration: InputDecoration(
              labelText: 'Password',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              prefixIcon: const Icon(Icons.lock_outlined),
            ),
            obscureText: true,
          ),
          const SizedBox(height: 24),
          Consumer<AuthState>(
            builder: (context, authState, _) {
              return ElevatedButton(
                onPressed: authState.isLoading
                    ? null
                    : () {
                        final email = _emailController.text;
                        final password = _passwordController.text;
                        if (email.isEmpty || password.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Please fill in all fields')),
                          );
                          return;
                        }
                        final router = GoRouter.of(context);
                        authState.loginWithEmail(email: email, password: password).then((success) {
                          if (mounted && success) {
                            _rememberEmail(email);
                            router.go('/dashboard');
                          }
                        });
                      },
                child: authState.isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Login'),
              );
            },
          ),
          const SizedBox(height: 16),
          if (context.watch<AuthState>().errorMessage != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                border: Border.all(color: Colors.red),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                context.watch<AuthState>().errorMessage!,
                style: TextStyle(color: Colors.red.shade700),
              ),
            ),
          _buildDevAccountPicker(context.watch<AuthState>()),
        ],
      ),
    );
  }

  Widget _buildPhoneLoginPage(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 32),
          Icon(
            Icons.phone,
            size: 64,
            color: Theme.of(context).primaryColor,
          ),
          const SizedBox(height: 24),
          Text(
            'Login with Phone',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 32),
          TextField(
            controller: _phoneController,
            decoration: InputDecoration(
              labelText: 'Phone Number',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              prefixIcon: const Icon(Icons.phone_outlined),
              hintText: '+212612345678',
            ),
            keyboardType: TextInputType.phone,
          ),
          const SizedBox(height: 24),
          Consumer<AuthState>(
            builder: (context, authState, _) {
              return ElevatedButton(
                onPressed: authState.isLoading
                    ? null
                    : () {
                        final phone = _phoneController.text;
                        if (phone.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Please enter a phone number')),
                          );
                          return;
                        }
                        final router = GoRouter.of(context);
                        authState.loginWithPhone(phone: phone).then((success) {
                          if (mounted && success) {
                            router.push(
                              '/login/otp?phone=${Uri.encodeComponent(phone)}',
                            );
                          }
                        });
                      },
                child: authState.isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Send OTP'),
              );
            },
          ),
          const SizedBox(height: 16),
          if (context.watch<AuthState>().errorMessage != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                border: Border.all(color: Colors.red),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                context.watch<AuthState>().errorMessage!,
                style: TextStyle(color: Colors.red.shade700),
              ),
            ),
        ],
      ),
    );
  }

}
