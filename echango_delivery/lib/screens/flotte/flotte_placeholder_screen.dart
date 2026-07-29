import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../state/auth_state.dart';
import '../../widgets/language_selector.dart';

/// Espace « gestionnaire de flotte » — pas encore construit.
///
/// Cet écran existe pour que le rôle soit **refusé proprement**. Sans lui,
/// `AuthState.homePath` renvoyait `/flotte`, une route absente du routeur :
/// un compte flotte qui se connecte tombait sur l'écran d'erreur de
/// `go_router`, sans explication ni moyen de repartir. Un compte flotte est
/// pourtant créé à chaque exécution des scripts de test, donc le cas se
/// produit en pratique.
class FlottePlaceholderScreen extends StatelessWidget {
  const FlottePlaceholderScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Gestion de flotte'),
        actions: const [LanguageSelector()],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.construction_outlined,
                  size: 72, color: theme.colorScheme.outline),
              const SizedBox(height: 24),
              Text(
                'Espace non disponible',
                style: theme.textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                'L\'interface de gestion de flotte n\'est pas encore intégrée à '
                'l\'application. Les opérations de flotte passent pour l\'instant '
                'par la console Fleetbase.',
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              OutlinedButton.icon(
                onPressed: () async {
                  await context.read<AuthState>().logout();
                  if (context.mounted) context.go('/login');
                },
                icon: const Icon(Icons.logout),
                label: const Text('Changer de compte'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
