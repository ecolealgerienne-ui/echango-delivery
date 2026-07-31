import 'dart:ui' show Locale;

/// Libellés d'interface du profil « entreprise de transport ».
///
/// ── Pourquoi ce fichier existe, et pourquoi seulement pour ce profil ───────
///
/// La règle 4 du projet interdit les chaînes en dur : le serveur renvoie un
/// **code**, l'app traduit. C'est appliqué aux erreurs depuis le 29/07
/// (`error_translator.dart`), mais **rien n'existait pour les libellés
/// d'interface** — d'où les ~575 chaînes françaises en dur des écrans
/// existants, assumées comme dette (`docs/audit_i18n_erreurs.md`).
///
/// CLAUDE.md tranche le cas d'un écran neuf : « Tout **nouvel** écran doit
/// néanmoins éviter d'en ajouter. » Les écrans du profil flotte sont neufs, ils
/// n'héritent donc de rien — et la dette n'a pas à grandir du seul fait qu'on
/// ajoute un profil.
///
/// ── Pourquoi ce mécanisme-ci, et pas une génération ARB ───────────────────
///
/// `flutter gen-l10n` est l'outil canonique, mais il **ne peut pas être
/// exécuté ici** : aucune toolchain Flutter dans cet environnement, et une
/// génération invérifiable est exactement ce que ce projet refuse d'introduire
/// (même motif qu'au 29/07 : « pas de génération ARB — invérifiable sans
/// toolchain Flutter »).
///
/// On reprend donc le patron qui a fait ses preuves ici : deux tables, une par
/// langue, avec la même contrainte — **les clés doivent être strictement
/// identiques**, ce que `tool/check_error_codes.dart` vérifie déjà pour les
/// erreurs et que le même outil couvre désormais pour celles-ci.
///
/// Un libellé manquant retombe sur sa clé plutôt que sur du français brut :
/// une clé à l'écran est laide et se corrige, une phrase dans la mauvaise
/// langue au milieu d'un écran arabe passe pour un défaut de l'application.
String fleetLabel(String key, Locale locale) {
  final table = locale.languageCode == 'ar' ? _ar : _fr;
  return table[key] ?? _fr[key] ?? key;
}

const Map<String, String> _fr = {
  // ── Navigation et titres ────────────────────────────────────────────────
  'fleet.title': 'Mon entreprise',
  'fleet.tab.orders': 'Mes courses',
  'fleet.tab.opportunities': 'Courses libres',
  'fleet.tab.drivers': 'Conducteurs',
  'fleet.tab.cash': 'Caisse',

  // ── Courses ─────────────────────────────────────────────────────────────
  'fleet.orders.empty': 'Aucune course confiée à votre entreprise.',
  'fleet.orders.empty.hint':
      'Prenez une course libre, ou attendez qu’un commerçant vous en confie une.',
  'fleet.orders.unassigned': 'Aucun conducteur désigné',
  'fleet.orders.assign': 'Désigner un conducteur',
  'fleet.orders.assigned_to': 'Conducteur',
  'fleet.orders.pickup': 'Enlèvement',
  'fleet.orders.dropoff': 'Livraison',
  'fleet.orders.price': 'Rémunération',
  'fleet.orders.cod': 'À encaisser à la porte',
  'fleet.orders.status': 'Statut',
  'fleet.orders.refresh': 'Actualiser',

  // ── Opportunités ────────────────────────────────────────────────────────
  'fleet.opportunities.empty': 'Aucune course libre pour le moment.',
  'fleet.opportunities.empty.hint':
      'Les courses diffusées et non encore prises apparaissent ici.',
  'fleet.opportunities.take': 'Prendre cette course',
  'fleet.opportunities.taking': 'Prise en cours…',
  'fleet.opportunities.taken': 'Course prise. Désignez un conducteur.',
  // ⚠️ Ce libellé n'est pas décoratif : la livraison est volontairement
  // réduite à sa commune tant que personne ne s'est engagé, et sans phrase
  // l'entreprise croirait à une donnée manquante.
  'fleet.opportunities.masked':
      'Adresse exacte communiquée une fois la course prise.',

  // ── Conducteurs ─────────────────────────────────────────────────────────
  'fleet.drivers.empty': 'Aucun conducteur rattaché à votre entreprise.',
  'fleet.drivers.add': 'Ajouter un conducteur',
  'fleet.drivers.name': 'Nom',
  'fleet.drivers.email': 'Email',
  'fleet.drivers.phone': 'Téléphone',
  'fleet.drivers.online': 'En ligne',
  'fleet.drivers.offline': 'Hors ligne',
  'fleet.drivers.select': 'Choisir un conducteur',

  // ── Caisse ──────────────────────────────────────────────────────────────
  'fleet.cash.title': 'Caisse de l’entreprise',
  'fleet.cash.owed_by_drivers': 'Ce que vos conducteurs vous doivent',
  'fleet.cash.owed_to_merchants': 'Ce que vous devez aux commerçants',
  'fleet.cash.empty': 'Aucun mouvement d’espèces.',

  // ── États partagés ──────────────────────────────────────────────────────
  'fleet.loading': 'Chargement…',
  'fleet.retry': 'Réessayer',
  'fleet.cancel': 'Annuler',
  'fleet.confirm': 'Confirmer',
};

const Map<String, String> _ar = {
  'fleet.title': 'شركتي',
  'fleet.tab.orders': 'رحلاتي',
  'fleet.tab.opportunities': 'رحلات متاحة',
  'fleet.tab.drivers': 'السائقون',
  'fleet.tab.cash': 'الصندوق',

  'fleet.orders.empty': 'لا توجد رحلات مسندة إلى شركتك.',
  'fleet.orders.empty.hint': 'خذ رحلة متاحة، أو انتظر أن يسندها إليك تاجر.',
  'fleet.orders.unassigned': 'لم يتم تعيين سائق',
  'fleet.orders.assign': 'تعيين سائق',
  'fleet.orders.assigned_to': 'السائق',
  'fleet.orders.pickup': 'الاستلام',
  'fleet.orders.dropoff': 'التسليم',
  'fleet.orders.price': 'الأجرة',
  'fleet.orders.cod': 'المبلغ المطلوب عند الباب',
  'fleet.orders.status': 'الحالة',
  'fleet.orders.refresh': 'تحديث',

  'fleet.opportunities.empty': 'لا توجد رحلات متاحة حالياً.',
  'fleet.opportunities.empty.hint': 'تظهر هنا الرحلات المنشورة وغير المأخوذة بعد.',
  'fleet.opportunities.take': 'خذ هذه الرحلة',
  'fleet.opportunities.taking': 'جاري الأخذ…',
  'fleet.opportunities.taken': 'تم أخذ الرحلة. عيّن سائقاً.',
  'fleet.opportunities.masked': 'يُكشف العنوان الدقيق بعد أخذ الرحلة.',

  'fleet.drivers.empty': 'لا يوجد سائقون مرتبطون بشركتك.',
  'fleet.drivers.add': 'إضافة سائق',
  'fleet.drivers.name': 'الاسم',
  'fleet.drivers.email': 'البريد الإلكتروني',
  'fleet.drivers.phone': 'الهاتف',
  'fleet.drivers.online': 'متصل',
  'fleet.drivers.offline': 'غير متصل',
  'fleet.drivers.select': 'اختر سائقاً',

  'fleet.cash.title': 'صندوق الشركة',
  'fleet.cash.owed_by_drivers': 'ما يدين به سائقوك لك',
  'fleet.cash.owed_to_merchants': 'ما تدين به للتجار',
  'fleet.cash.empty': 'لا توجد حركات نقدية.',

  'fleet.loading': 'جاري التحميل…',
  'fleet.retry': 'إعادة المحاولة',
  'fleet.cancel': 'إلغاء',
  'fleet.confirm': 'تأكيد',
};

/// Les deux tables, exposées pour un usage programmatique.
///
/// ⚠️ `tool/check_error_codes.dart` **n'utilise pas** cette constante : il
/// analyse le source par expression régulière, comme il le fait déjà pour les
/// deux tables d'erreurs. Le commentaire précédent affirmait le contraire —
/// une description de mécanisme inexistant, qui aurait fait croire à quiconque
/// renomme ces tables que le vérificateur suivrait.
const Map<String, Map<String, String>> fleetLabelTables = {'fr': _fr, 'ar': _ar};
