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
import '../../widgets/notice.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  String _t(String key, [Map<String, String>? vars]) =>
      authLabel(key, context.read<LocaleState>().locale, vars);

  /// Le profil que l'on crée.
  ///
  /// ⚠️ Les trois parcours existaient côté serveur ; deux n'avaient **aucun
  /// écran** (revue du 01/08/2026, A1). Un seul formulaire les sert, parce
  /// qu'ils demandent presque les mêmes champs : ce qui change, c'est le nom
  /// (commerce / entreprise / personne) et le code d'invitation.
  UserRole _as = UserRole.commercant;

  final _businessController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _phoneController = TextEditingController();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _invitationController = TextEditingController();

  @override
  void dispose() {
    _businessController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _phoneController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    _invitationController.dispose();
    super.dispose();
  }

  Future<void> _submit(AuthState authState) async {
    final business = _businessController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final invitation = _invitationController.text.trim();

    // Le champ qui manque n'est pas le même selon le profil, et le message le
    // dit : « Commerce, email et mot de passe sont requis » sous un formulaire
    // qui demande un code d'invitation enverrait chercher au mauvais endroit.
    final missing = switch (_as) {
      UserRole.commercant => business.isEmpty || email.isEmpty || password.isEmpty
          ? 'auth.register.missing'
          : null,
      UserRole.flotte => business.isEmpty || email.isEmpty || password.isEmpty
          ? 'auth.register.missing.fleet'
          : null,
      UserRole.transporteur => invitation.isEmpty || email.isEmpty || password.isEmpty
          ? 'auth.register.missing.driver'
          : null,
    };
    if (missing != null) {
      showAppError(context, _t(missing));
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
    final firstName = _firstNameController.text.trim();
    final lastName = _lastNameController.text.trim();
    final phone = _phoneController.text.trim();

    final success = switch (_as) {
      UserRole.commercant => await authState.registerMerchant(
          email: email,
          password: password,
          businessName: business,
          phone: phone,
        ),
      UserRole.flotte => await authState.registerFleet(
          email: email,
          password: password,
          businessName: business,
          firstName: firstName,
          lastName: lastName,
          phone: phone,
        ),
      UserRole.transporteur => await authState.registerDriver(
          invitationToken: invitation,
          email: email,
          password: password,
          firstName: firstName,
          lastName: lastName,
          phone: phone,
        ),
    };
    if (!mounted) return;

    // ⚠️ On ne navigue que si une session existe VRAIMENT.
    //
    // Commerçant et entreprise se terminent par `*_pending` : la demande est
    // enregistrée, l'accès pas encore ouvert, et il n'y a pas de jeton. Aller
    // sur `homePath` renverrait aussitôt vers `/login` par le garde du routeur,
    // en effaçant au passage le message qui explique pourquoi. Seul le
    // transporteur, dont l'invitation vaut validation, entre directement.
    if (success && authState.isAuthenticated) router.go(authState.homePath);
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
                  Text(_t('auth.register.as'),
                      style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: AppSpacing.sm),
                  SegmentedButton<UserRole>(
                    segments: [
                      ButtonSegment(
                        value: UserRole.commercant,
                        label: Text(_t('auth.register.as.merchant')),
                        icon: const Icon(Icons.storefront_outlined),
                      ),
                      ButtonSegment(
                        value: UserRole.flotte,
                        label: Text(_t('auth.register.as.fleet')),
                        icon: const Icon(Icons.business_outlined),
                      ),
                      ButtonSegment(
                        value: UserRole.transporteur,
                        label: Text(_t('auth.register.as.driver')),
                        icon: const Icon(Icons.two_wheeler_outlined),
                      ),
                    ],
                    selected: {_as},
                    onSelectionChanged: (v) => setState(() => _as = v.first),
                  ),
                  const SizedBox(height: AppSpacing.xl),

                  // Le code d'invitation vient EN PREMIER pour un transporteur :
                  // c'est ce qu'il tient dans la main, et sans lui rien d'autre
                  // ne sert. Personne ne s'inscrit transporteur de soi-même.
                  if (_as == UserRole.transporteur) ...[
                    TextField(
                      controller: _invitationController,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: _t('auth.register.invitation'),
                        helperText: _t('auth.register.invitation.hint'),
                        prefixIcon: const Icon(Icons.confirmation_number_outlined),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _firstNameController,
                            decoration: InputDecoration(
                              labelText: _t('auth.register.driver.name'),
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: TextField(
                            controller: _lastNameController,
                            decoration: InputDecoration(
                              labelText: _t('auth.register.driver.lastname'),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.lg),
                  ] else
                    TextField(
                      controller: _businessController,
                      decoration: InputDecoration(
                        labelText: _as == UserRole.flotte
                            ? _t('auth.register.fleet.name')
                            : _t('auth.register.name'),
                        helperText: _as == UserRole.flotte
                            ? _t('auth.register.fleet.name.hint')
                            : _t('auth.register.name.hint'),
                        prefixIcon: Icon(_as == UserRole.flotte
                            ? Icons.business_outlined
                            : Icons.storefront_outlined),
                      ),
                    ),
                  if (_as != UserRole.transporteur)
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
                  // ⚠️ Une demande enregistrée n'est PAS une erreur. Avant, le
                  // serveur terminant l'inscription par `merchant_pending`, une
                  // inscription réussie s'affichait en bandeau rouge — comme un
                  // mot de passe trop court.
                  if (authState.pendingMessage != null) ...[
                    const SizedBox(height: AppSpacing.lg),
                    AppNotice.success(
                      icon: Icons.mark_email_read_outlined,
                      title: _t('auth.register.pending.title'),
                      message: authState.pendingMessage!,
                    ),
                  ],
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
