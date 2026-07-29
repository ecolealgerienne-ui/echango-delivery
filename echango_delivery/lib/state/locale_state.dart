import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _localeKey = 'echango_locale';

/// Langues supportées par l'app (CLAUDE.md, 29/07/2026 : français + arabe).
///
/// Liste fermée plutôt qu'un `Locale` libre : le sélecteur de langue
/// (Task #33) et le traducteur d'erreurs (`error_translator.dart`) n'ont de
/// texte que pour ces deux-là. Une troisième langue ajoutée un jour devra
/// passer par les deux à la fois, jamais par l'une sans l'autre.
const List<Locale> supportedLocales = [Locale('fr'), Locale('ar')];

/// Langue active de l'application, persistée entre les lancements.
///
/// ── Pourquoi un état à part, et pas juste `Localizations.localeOf` ──────
///
/// Le choix de langue est **explicite** (sélecteur à l'écran), pas déduit de
/// la locale système à chaque démarrage : un utilisateur qui a choisi le
/// français sur un téléphone configuré en arabe ne doit pas être ramené à
/// l'arabe au lancement suivant. La locale système ne sert qu'une fois, comme
/// valeur par défaut la toute première fois que l'app démarre sans choix
/// enregistré.
class LocaleState extends ChangeNotifier {
  final SharedPreferences _prefs;

  late Locale _locale;

  LocaleState({required SharedPreferences prefs, Locale? systemLocale})
      : _prefs = prefs {
    final saved = _prefs.getString(_localeKey);
    final fromSave = saved == null
        ? null
        : supportedLocales.where((l) => l.languageCode == saved).firstOrNull;
    final fromSystem = systemLocale == null
        ? null
        : supportedLocales
            .where((l) => l.languageCode == systemLocale.languageCode)
            .firstOrNull;
    _locale = fromSave ?? fromSystem ?? supportedLocales.first;
  }

  Locale get locale => _locale;

  Future<void> setLocale(Locale locale) async {
    if (!supportedLocales.any((l) => l.languageCode == locale.languageCode)) {
      return;
    }
    if (_locale.languageCode == locale.languageCode) return;
    _locale = locale;
    await _prefs.setString(_localeKey, locale.languageCode);
    notifyListeners();
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
