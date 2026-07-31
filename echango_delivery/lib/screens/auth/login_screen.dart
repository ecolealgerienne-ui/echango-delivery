import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../config/dev_accounts.dart';
import '../../state/auth_state.dart';
import '../../widgets/app_snack_bar.dart';
import '../../widgets/error_banner.dart';
import '../../widgets/language_selector.dart';
import '../../theme/app_spacing.dart';

/// Dernier email utilisé, pré-rempli au lancement suivant. L'email seul —
/// jamais le mot de passe, qui n'a rien à faire dans des préférences en clair.
const _lastEmailKey = 'echango_last_email';

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
    final email = prefs.getString(_lastEmailKey);
    if (!mounted) return;
    if (email != null && _emailController.text.isEmpty) {
      setState(() => _emailController.text = email);
    }
  }

  Future<void> _remember(String email) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastEmailKey, email);
  }

  /// [role] n'est renseigné que pour lever une ambiguïté signalée par le
  /// serveur — jamais choisi à l'avance par l'utilisateur.
  Future<void> _submit(AuthState authState,
      {DevAccount? account, UserRole? role}) async {
    final email = account?.email ?? _emailController.text.trim();
    final password = account?.password ?? _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      showAppError(context, 'Renseigner l\'email et le mot de passe');
      return;
    }

    final router = GoRouter.of(context);
    final success =
        await authState.login(email: email, password: password, role: role);
    if (!mounted) return;
    if (success) {
      await _remember(email);
      router.go(authState.homePath);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = context.watch<AuthState>();

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Align(
                    alignment: Alignment.centerRight,
                    child: LanguageSelector(),
                  ),
                  Icon(Icons.local_shipping,
                      size: 56, color: Theme.of(context).primaryColor),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    'Echango Delivery',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: AppSpacing.xxl),

                  // Aucun choix de profil demandé : le serveur le résout depuis
                  // l'email, seul à savoir dans quelle table le compte existe.
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
                  const SizedBox(height: AppSpacing.lg),
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
                  const SizedBox(height: AppSpacing.xl),
                  ElevatedButton(
                    onPressed:
                        authState.isLoading ? null : () => _submit(authState),
                    child: authState.isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Se connecter'),
                  ),

                  const SizedBox(height: AppSpacing.sm),
                  // Seul le commerçant peut s'inscrire seul : un transporteur
                  // est provisionné par un opérateur, son compte Echango se
                  // rattache ensuite à son Driver Fleetbase. Comme on ignore
                  // qui se présente, l'entrée reste visible et le texte lève
                  // l'ambiguïté.
                  TextButton(
                    onPressed: () => context.push('/register'),
                    child: const Text('Créer un compte commerçant'),
                  ),
                  Text(
                    'Les accès transporteur sont créés par Echango.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),

                  // Cas rare : un même identifiant vaut pour plusieurs profils.
                  // Le serveur refuse de trancher à la place de l'utilisateur.
                  if (authState.ambiguousRoles.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.lg),
                    Text('Ouvrir en tant que',
                        style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: AppSpacing.sm),
                    Wrap(
                      spacing: 8,
                      children: authState.ambiguousRoles
                          .map((r) => ActionChip(
                                label: Text(r.label),
                                onPressed: authState.isLoading
                                    ? null
                                    : () => _submit(authState, role: r),
                              ))
                          .toList(),
                    ),
                  ],

                  if (authState.errorMessage != null) ...[
                    const SizedBox(height: AppSpacing.lg),
                    AppErrorBanner(message: authState.errorMessage!),
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

  /// Comptes de test, debug uniquement et fournis au build (dev_accounts.dart).
  /// Basculer d'un profil à l'autre en un tap est précisément ce qu'on veut
  /// pour tester les deux côtés d'une même livraison.
  Widget _buildDevAccounts(AuthState authState) {
    final accounts = DevAccounts.accounts;
    if (accounts.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: AppSpacing.xl),
        Text(
          'Comptes de test (debug)',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: accounts.map((a) {
            final role = UserRoleX.fromJwtType(a.role);
            return ActionChip(
              avatar: Icon(
                role == UserRole.commercant
                    ? Icons.storefront
                    : Icons.two_wheeler,
                size: 18,
              ),
              label: Text(a.label),
              // Aucun profil transmis : le serveur résout, comme pour une
              // connexion manuelle. Le `role` du compte de test ne sert qu'à
              // choisir l'icône.
              onPressed: authState.isLoading
                  ? null
                  : () => _submit(authState, account: a),
            );
          }).toList(),
        ),
      ],
    );
  }
}
