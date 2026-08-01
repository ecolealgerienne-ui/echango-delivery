import 'dart:ui' show Locale;

/// Les mots que **tous** les profils emploient.
///
/// ── Pourquoi une table de plus, et pas une clé dans celle des livraisons ──
///
/// Parce que ces libellés n'appartiennent à aucun domaine : « Réessayer »,
/// « Annuler », « Retour » sont de l'ossature. Les ranger dans `order_strings`
/// ferait importer le vocabulaire d'une livraison à `AppErrorBanner`, qui sert
/// aussi la caisse et l'espace entreprise.
///
/// ⚠️ **« Réessayer » était écrit trois fois** — dans `AppEmptyState`,
/// `AppErrorBanner` et `AppNotice`, chacun en repli de son `retryLabel`. Trois
/// copies du même défaut, dans trois composants partagés dont le rôle est
/// justement d'empêcher ça. Trouvé en corrigeant l'extracteur de chaînes, pas
/// en relisant.
String commonLabel(String key, Locale locale, [Map<String, String>? vars]) {
  final table = locale.languageCode == 'ar' ? _ar : _fr;
  var value = table[key] ?? _fr[key] ?? key;

  if (vars != null) {
    for (final entry in vars.entries) {
      value = value.replaceAll('{${entry.key}}', entry.value);
    }
  }
  return value;
}

/// Les deux tables, exposées pour le vérificateur de clés.
const Map<String, Map<String, String>> commonLabelTables = {'fr': _fr, 'ar': _ar};

const Map<String, String> _fr = {
  // ── Ossature ────────────────────────────────────────────────────────────
  'common.retry': 'Réessayer',
  'common.cancel': 'Annuler',
  'common.back': 'Retour',

  // ── Accueil ─────────────────────────────────────────────────────────────
  // ⚠️ « Echango Delivery » n'est PAS ici : une marque ne se traduit pas.
  'common.splash.tagline': 'Commandez, livrez, suivez',

  // ── Sélecteur de langue ─────────────────────────────────────────────────
  //
  // Chaque libellé est écrit dans la langue **vers laquelle** il fait basculer,
  // et non dans la langue courante : c'est ce qui rend le bouton lisible par
  // quelqu'un qui ne comprend pas l'écran où il se trouve. Les deux tables
  // portent donc la même valeur, et c'est voulu.
  'common.language.to_fr': 'Passer en français',
  'common.language.to_ar': 'التبديل إلى العربية',

  // ── Photo ───────────────────────────────────────────────────────────────
  'common.photo': 'Photo',
  'common.photo.take': 'Photographier',
  'common.photo.retake': 'Reprendre',
  'common.photo.remove': 'Retirer',
  'common.photo.size': '{size} ko',
  'common.photo.load_failed': 'Photo enregistrée, mais son chargement a échoué.',
};

const Map<String, String> _ar = {
  // ── Ossature ────────────────────────────────────────────────────────────
  'common.retry': 'إعادة المحاولة',
  'common.cancel': 'إلغاء',
  'common.back': 'رجوع',

  // ── Accueil ─────────────────────────────────────────────────────────────
  'common.splash.tagline': 'اطلب، وصّل، تابع',

  // ── Sélecteur de langue ─────────────────────────────────────────────────
  // Identiques au français, et c'est la règle : chaque libellé est dans la
  // langue vers laquelle il bascule.
  'common.language.to_fr': 'Passer en français',
  'common.language.to_ar': 'التبديل إلى العربية',

  // ── Photo ───────────────────────────────────────────────────────────────
  'common.photo': 'صورة',
  'common.photo.take': 'التقاط صورة',
  'common.photo.retake': 'إعادة الالتقاط',
  'common.photo.remove': 'إزالة',
  'common.photo.size': '{size} ك.ب',
  'common.photo.load_failed': 'حُفظت الصورة، لكن تعذّر تحميلها.',
};
