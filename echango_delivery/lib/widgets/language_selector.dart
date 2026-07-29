import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/locale_state.dart';

/// Sélecteur de langue (français / arabe), posé sur les écrans d'entrée de
/// chaque profil (connexion, et l'accueil des trois personas) plutôt que
/// dans un menu de réglages enfoui : c'est un choix qu'on fait une fois, tôt,
/// et qu'on doit pouvoir changer aussi facilement qu'on l'a fait.
///
/// Deux langues seulement (`supportedLocales`) : un bouton bascule direct,
/// affichant la langue vers laquelle il bascule plutôt qu'un menu à un seul
/// autre choix — plus rapide qu'ouvrir puis choisir dans une liste d'un
/// élément.
class LanguageSelector extends StatelessWidget {
  const LanguageSelector({super.key});

  @override
  Widget build(BuildContext context) {
    final localeState = context.watch<LocaleState>();
    final isArabic = localeState.locale.languageCode == 'ar';
    final target = isArabic ? const Locale('fr') : const Locale('ar');
    final label = isArabic ? 'FR' : 'AR';
    final tooltip = isArabic ? 'Passer en français' : 'التبديل إلى العربية';

    return Tooltip(
      message: tooltip,
      child: TextButton.icon(
        onPressed: () => localeState.setLocale(target),
        icon: const Icon(Icons.language, size: 18),
        label: Text(label),
        style: TextButton.styleFrom(
          foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
