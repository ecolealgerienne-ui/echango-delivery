import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../i18n/auth_strings.dart';
import '../../state/locale_state.dart';
import '../../state/auth_state.dart';
import '../../config/app_rules.dart';
import '../../theme/app_spacing.dart';
import '../../widgets/app_snack_bar.dart';
import '../../widgets/error_banner.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  String _t(String key, [Map<String, String>? vars]) =>
      authLabel(key, context.read<LocaleState>().locale, vars);

  final _businessController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _phoneController = TextEditingController();

  @override
  void dispose() {
    _businessController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _submit(AuthState authState) async {
    final business = _businessController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (business.isEmpty || email.isEmpty || password.isEmpty) {
      showAppError(context, _t('auth.register.missing'));
      return;
    }
    // Contrainte serveur : la vérifier ici évite un aller-retour pour un
    // message que l'on connaît d'avance. La valeur vit dans `ServerRules`, et
    // `tool/check_server_rules.dart` vérifie qu'elle n'a pas dérivé du DTO.
    if (password.length < ServerRules.passwordMinLength) {
      showAppError(
        context,
        _t('auth.register.password.short',
            {'n': '${ServerRules.passwordMinLength}'}),
      );
      return;
    }

    final router = GoRouter.of(context);
    final success = await authState.registerMerchant(
      email: email,
      password: password,
      businessName: business,
      phone: _phoneController.text.trim(),
    );
    if (!mounted) return;
    if (success) router.go(authState.homePath);
  }

  @override
  Widget build(BuildContext context) {
    final authState = context.watch<AuthState>();

    return Scaffold(
      appBar: AppBar(title: Text(_t('auth.register.title'))),
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
                  TextField(
                    controller: _businessController,
                    decoration: InputDecoration(
                      labelText: _t('auth.register.name'),
                      helperText: _t('auth.register.name.hint'),
                      prefixIcon: const Icon(Icons.storefront_outlined),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  TextField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: _t('auth.register.email'),
                      prefixIcon: const Icon(Icons.email_outlined),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  TextField(
                    controller: _passwordController,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: _t('auth.register.password'),
                      // Interpolé, pas figé : la garde (`_submit`) et le
                      // SnackBar suivent déjà la constante. Laisser « 8 » ici
                      // afficherait « 8 caractères minimum » sous un champ qui
                      // en refuserait neuf le jour où le serveur passe à dix.
                      helperText: _t('auth.register.password.hint',
                          {'n': '${ServerRules.passwordMinLength}'}),
                      prefixIcon: const Icon(Icons.lock_outlined),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  TextField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    decoration: InputDecoration(
                      labelText: _t('auth.register.phone'),
                      prefixIcon: const Icon(Icons.phone_outlined),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  FilledButton(
                    onPressed: authState.isLoading ? null : () => _submit(authState),
                    child: authState.isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(_t('auth.register.submit')),
                  ),
                  if (authState.errorMessage != null) ...[
                    const SizedBox(height: AppSpacing.lg),
                    AppErrorBanner(message: authState.errorMessage!),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
