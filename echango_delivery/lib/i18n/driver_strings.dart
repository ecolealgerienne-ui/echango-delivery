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
  // ── L'état d'une course, dit au transporteur ────────────────────────────
  //
  // ⚠️ Les CLÉS viennent d'`orderStateKey`, partagé avec le profil entreprise :
  // la décision « dans quel état est cette course » est un invariant, et elle
  // est écrite une seule fois (règle 5). Les LIBELLÉS, eux, restent séparés, et
  // le critère de la règle 5 répond non : l'entreprise parle d'un tiers
  // (« Conducteur désigné »), le transporteur parle de lui-même (« À
  // démarrer »). Si l'un change, l'autre n'a aucune raison de changer.
  //
  // Avant le 01/08/2026, cet écran affichait le statut Fleetbase NU —
  // « Statut : dispatched », « Statut : enroute » —, donc en arabe une phrase
  // arabe terminée par un mot anglais. Le transporteur était le seul des trois
  // profils dans ce cas.
  'driver.state.draft': 'Brouillon',
  'driver.state.broadcast': 'Proposée au réseau',
  'driver.state.taken': 'Retirée du réseau',
  'driver.state.awaiting_start': 'À démarrer',
  'driver.state.enroute': 'En cours de livraison',
  'driver.state.completed': 'Livrée',
  'driver.state.canceled': 'Annulée',
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

  // ── Ma zone de travail ────────────────────────────────────────────────────
  //
  // ⚠️ Les textes d'aide portent l'essentiel : un filtre mal compris se lit
  // comme une panne. Ils disent donc explicitement ce qui n'est PAS filtré —
  // tant qu'on n'a rien choisi, et quand la position est inconnue.
  'driver.zone.title': 'Ma zone de travail',
  'driver.zone.subtitle':
      'Choisissez où vous voulez voir des courses. Tant que rien n’est '
      'enregistré, vous les voyez toutes.',
  'driver.zone.wilaya': 'Wilaya',
  'driver.zone.wilaya.hint':
      'Seules les courses dont l’enlèvement est dans cette wilaya vous seront '
      'proposées. Laissez vide pour toutes les voir.',
  'driver.zone.radius': 'Rayon autour de moi',
  'driver.zone.radius.hint':
      'Affine la liste autour de votre position actuelle.',
  'driver.zone.radius.no_position':
      'Votre position n’est pas connue : ce rayon ne s’applique pas pour '
      'l’instant. Seule la wilaya filtre.',
  'driver.zone.km': 'km',
  'driver.zone.state.none': 'Aucun filtre : vous voyez toutes les courses.',
  'driver.zone.state.active': 'Filtre actif — wilaya : {wilaya}.',
  'driver.zone.all_wilayas': 'toutes',
  'driver.zone.save': 'Enregistrer',
  'driver.zone.clear': 'Tout voir',
  'driver.zone.saved': 'Zone enregistrée.',
  'driver.zone.cleared': 'Filtre retiré : vous voyez toutes les courses.',
  'driver.zone.load_failed': 'Impossible de lire votre zone de travail.',
  'driver.zone.save_failed': 'Zone non enregistrée. Réessayez.',
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
  'driver.state.draft': 'مسودة',
  'driver.state.broadcast': 'معروضة على الشبكة',
  'driver.state.taken': 'سُحبت من الشبكة',
  'driver.state.awaiting_start': 'في انتظار الانطلاق',
  'driver.state.enroute': 'جارية التوصيل',
  'driver.state.completed': 'سُلّمت',
  'driver.state.canceled': 'أُلغيت',
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

  // ── منطقة عملي ────────────────────────────────────────────────────────────
  'driver.zone.title': 'منطقة عملي',
  'driver.zone.subtitle':
      'اختر أين تريد رؤية الرحلات. ما لم تسجّل شيئاً، فأنت ترى كل الرحلات.',
  'driver.zone.wilaya': 'الولاية',
  'driver.zone.wilaya.hint':
      'لن تُعرض عليك إلا الرحلات التي يقع الاستلام فيها بهذه الولاية. اتركه '
      'فارغاً لرؤيتها كلها.',
  'driver.zone.radius': 'النطاق حولي',
  'driver.zone.radius.hint': 'يضيّق القائمة حول موقعك الحالي.',
  'driver.zone.radius.no_position':
      'موقعك غير معروف: هذا النطاق لا يُطبَّق حالياً. الولاية وحدها تصفّي.',
  'driver.zone.km': 'كم',
  'driver.zone.state.none': 'لا تصفية: أنت ترى كل الرحلات.',
  'driver.zone.state.active': 'تصفية مفعّلة — الولاية: {wilaya}.',
  'driver.zone.all_wilayas': 'الكل',
  'driver.zone.save': 'حفظ',
  'driver.zone.clear': 'عرض الكل',
  'driver.zone.saved': 'تم حفظ المنطقة.',
  'driver.zone.cleared': 'أُزيلت التصفية: أنت ترى كل الرحلات.',
  'driver.zone.load_failed': 'تعذّرت قراءة منطقة عملك.',
  'driver.zone.save_failed': 'لم تُحفظ المنطقة. أعد المحاولة.',
  'driver.vehicle.none': 'غير مصرَّح بها',
  'driver.vehicle.moto': 'دراجة نارية',
  'driver.vehicle.voiture': 'سيارة',
  'driver.vehicle.utilitaire': 'شاحنة صغيرة',
  'driver.vehicle.hint.none':
      'بدون مركبة مصرَّح بها، تُعرض عليك كل المهام.',
  'driver.vehicle.hint.set':
      'لن تُعرض عليك مهمة تتطلب مركبة أكبر.',
};
