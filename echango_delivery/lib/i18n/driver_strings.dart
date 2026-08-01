import 'dart:ui' show Locale;

import 'translate.dart';

/// L'espace transporteur : navigation, présence, profil, véhicule déclaré.
///
/// ── Pourquoi une table à part de `order_strings` ──────────────────────────
///
/// `order_strings` porte le vocabulaire d'**une livraison**, partagé par les
/// deux profils. Ici c'est l'ossature d'un profil : ses onglets, son
/// interrupteur « en ligne », sa déconnexion. Les mêler ferait importer les
/// onglets du conducteur à l'écran du commerçant, et le critère de la règle 5
/// répond non — si un onglet change, aucune fiche de livraison ne bouge.
///
/// Pendant exact de `fleet_strings.dart` pour le profil entreprise.
String driverLabel(String key, Locale locale, [Map<String, String>? vars]) =>
    translate(_fr, _ar, key, locale, vars);

/// Les deux tables, exposées pour le vérificateur de clés.
const Map<String, Map<String, String>> driverLabelTables = {'fr': _fr, 'ar': _ar};

const Map<String, String> _fr = {
  // ── Espace transporteur : navigation ────────────────────────────────────
  'driver.home.orders': 'Commandes',
  'driver.home.map': 'Carte',
  'driver.home.profile': 'Profil',
  'driver.home.cash': 'Ma caisse',
  'driver.home.fleets': 'Mes entreprises',

  // ── Présence ────────────────────────────────────────────────────────────
  'driver.presence.online': 'En ligne',
  'driver.presence.offline': 'Hors ligne',
  'driver.presence.offline.warning':
      'Vous êtes hors ligne : aucune course ne vous sera proposée.',
  'driver.presence.push.unavailable':
      'Notifications indisponibles sur cet appareil — la liste se rafraîchit '
          'automatiquement, avec un léger délai.',

  // ── Notification du service au premier plan ─────────────────────────────
  //
  // Ces quatre libellés s'affichent **hors de l'application** : dans le volet
  // de notifications Android et dans les réglages système du téléphone. Ce
  // sont les seules chaînes du projet dans ce cas, et c'est pourquoi elles
  // avaient échappé au relevé — personne ne cherche du texte d'interface dans
  // `services/`.
  'driver.presence.channel.name': 'Disponibilité transporteur',
  'driver.presence.channel.description':
      'Maintient le partage de position pendant que vous êtes en ligne.',
  'driver.presence.notification.title': 'Vous êtes en ligne',
  'driver.presence.notification.text':
      'Votre position est partagée pour recevoir des courses.',

  // ── Onglets et listes vides ─────────────────────────────────────────────
  'driver.tab.opportunities': 'Opportunités',
  'driver.tab.active': 'En cours',
  'driver.tab.history': 'Historique',
  'driver.empty.opportunities': 'Aucune opportunité à proximité',
  'driver.empty.opportunities.hint':
      'Vérifier que vous êtes en ligne : le dispatch est géographique.',
  'driver.empty.active': 'Aucune commande en cours',
  'driver.empty.active.hint':
      'Acceptez une course depuis l’onglet « Opportunités » pour la voir '
          'apparaître ici.',
  'driver.empty.history': 'Aucune commande terminée',
  'driver.empty.history.hint':
      'Vos courses livrées ou annulées se rangeront ici, avec leur preuve de '
          'remise.',
  'driver.empty.default': 'Aucune commande',
  'driver.order.card.number': 'Commande #{id}',
  'driver.order.card.status': 'Statut : {status}',

  // ── Carte (pas encore construite, et l'écran le dit) ────────────────────
  'driver.map.unavailable': 'Carte non disponible',
  'driver.map.unavailable.hint':
      'La carte des courses n’est pas encore implémentée.',

  // ── Profil ──────────────────────────────────────────────────────────────
  'driver.profile.fallback': 'Transporteur',
  'driver.profile.role': 'Profil : {role}',
  'driver.logout': 'Se déconnecter',
  'driver.logout.body':
      'Vous serez basculé hors ligne et ne recevrez plus de courses.',

  // ── Véhicule déclaré ────────────────────────────────────────────────────
  'driver.vehicle.title': 'Mon véhicule',
  'driver.vehicle.none': 'Non déclaré',
  'driver.vehicle.moto': 'Moto',
  'driver.vehicle.voiture': 'Voiture',
  'driver.vehicle.utilitaire': 'Utilitaire',
  'driver.vehicle.hint.none':
      'Sans véhicule déclaré, toutes les courses vous sont proposées.',
  'driver.vehicle.hint.set':
      'Une course exigeant un véhicule plus grand ne vous sera pas proposée.',
};

const Map<String, String> _ar = {
  // ── Espace transporteur : navigation ────────────────────────────────────
  'driver.home.orders': 'الطلبات',
  'driver.home.map': 'الخريطة',
  'driver.home.profile': 'الملف',
  'driver.home.cash': 'صندوقي',
  'driver.home.fleets': 'شركاتي',

  // ── Présence ────────────────────────────────────────────────────────────
  'driver.presence.online': 'متصل',
  'driver.presence.offline': 'غير متصل',
  'driver.presence.offline.warning':
      'أنت غير متصل: لن تُعرض عليك أي مهمة.',
  'driver.presence.push.unavailable':
      'الإشعارات غير متاحة على هذا الجهاز — تتحدّث القائمة تلقائيًا، مع تأخر '
          'بسيط.',

  // ── Notification du service au premier plan ─────────────────────────────
  'driver.presence.channel.name': 'توفّر الناقل',
  'driver.presence.channel.description':
      'يُبقي مشاركة الموقع فعّالة ما دمت متصلًا.',
  'driver.presence.notification.title': 'أنت متصل',
  'driver.presence.notification.text': 'يُشارَك موقعك لتلقّي المهام.',

  // ── Onglets et listes vides ─────────────────────────────────────────────
  'driver.tab.opportunities': 'الفرص',
  'driver.tab.active': 'الجارية',
  'driver.tab.history': 'السجل',
  'driver.empty.opportunities': 'لا توجد فرصة قريبة',
  'driver.empty.opportunities.hint':
      'تأكّد من أنك متصل: التوزيع يعتمد على الموقع الجغرافي.',
  'driver.empty.active': 'لا توجد مهمة جارية',
  'driver.empty.active.hint':
      'اقبل مهمة من تبويب «الفرص» لتظهر هنا.',
  'driver.empty.history': 'لا توجد مهمة منتهية',
  'driver.empty.history.hint':
      'ستُرتَّب هنا مهماتك المسلَّمة أو الملغاة، مع إثبات التسليم.',
  'driver.empty.default': 'لا توجد طلبات',
  'driver.order.card.number': 'الطلب #{id}',
  'driver.order.card.status': 'الحالة: {status}',

  // ── Carte ───────────────────────────────────────────────────────────────
  'driver.map.unavailable': 'الخريطة غير متاحة',
  'driver.map.unavailable.hint': 'خريطة المهام لم تُنجَز بعد.',

  // ── Profil ──────────────────────────────────────────────────────────────
  'driver.profile.fallback': 'ناقل',
  'driver.profile.role': 'الملف: {role}',
  'driver.logout': 'تسجيل الخروج',
  'driver.logout.body': 'ستصبح غير متصل ولن تتلقى مهمات بعد الآن.',

  // ── Véhicule déclaré ────────────────────────────────────────────────────
  'driver.vehicle.title': 'مركبتي',
  'driver.vehicle.none': 'غير مصرَّح بها',
  'driver.vehicle.moto': 'دراجة نارية',
  'driver.vehicle.voiture': 'سيارة',
  'driver.vehicle.utilitaire': 'شاحنة صغيرة',
  'driver.vehicle.hint.none':
      'بدون مركبة مصرَّح بها، تُعرض عليك كل المهام.',
  'driver.vehicle.hint.set':
      'لن تُعرض عليك مهمة تتطلب مركبة أكبر.',
};
