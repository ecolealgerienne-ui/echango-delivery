import 'dart:ui' show Locale;

/// Libellés d'interface du profil « entreprise de transport » — **et des écrans
/// de rattachement vus du conducteur**.
///
/// Ces derniers vivent ici et non dans une table à part parce que c'est **une
/// seule fonctionnalité vue des deux bouts** : l'entreprise demande, le
/// conducteur accepte, et les deux écrans nomment les mêmes états. Deux tables
/// auraient produit deux vocabulaires pour un même `pending`, ce que ce projet a
/// déjà payé (« deux tables recopiées ont affiché deux textes différents pour la
/// même commande »).
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
  'fleet.orders.more': 'Charger les courses précédentes',
  'fleet.orders.unassigned': 'Aucun conducteur désigné',
  'fleet.orders.assign': 'Désigner un conducteur',
  'fleet.orders.assigned_to': 'Conducteur',
  'fleet.orders.pickup': 'Enlèvement',
  'fleet.orders.dropoff': 'Livraison',
  'fleet.orders.price': 'Rémunération',
  'fleet.orders.cod': 'À encaisser à la porte',
  'fleet.orders.status': 'Statut',
  'fleet.orders.refresh': 'Actualiser',

  // ── État d'une course, composé de quatre champs ─────────────────────────
  //
  // ⚠️ Ces libellés remplacent l'affichage du `status` brut. « dispatched » ne
  // disait ni que la course était prise, ni qu'elle attendait un démarrage, ni
  // si quelqu'un d'autre pouvait encore la prendre. Voir
  // `models/fleet_order_state.dart` pour la composition.
  'fleet.state.draft': 'Non publiée par le commerçant',
  'fleet.state.broadcast': 'Diffusée — en attente d’un preneur',
  'fleet.state.taken': 'Prise — aucun conducteur désigné',
  'fleet.state.awaiting_start': 'Conducteur désigné — en attente de démarrage',
  'fleet.state.enroute': 'En cours de livraison',
  'fleet.state.completed': 'Livrée',
  'fleet.state.canceled': 'Annulée',

  // ── Opportunités ────────────────────────────────────────────────────────
  'fleet.opportunities.empty': 'Aucune course libre pour le moment.',
  'fleet.opportunities.empty.hint':
      'Les courses diffusées et non encore prises apparaissent ici.',
  'fleet.opportunities.more': 'Charger les courses suivantes',
  'fleet.opportunities.take': 'Prendre cette course',
  'fleet.opportunities.taking': 'Prise en cours…',
  'fleet.opportunities.taken': 'Course prise. Désignez un conducteur.',
  // ⚠️ Ce libellé n'est pas décoratif : le nom et le téléphone du destinataire
  // sont volontairement absents tant que personne ne s'est engagé, et sans
  // phrase l'entreprise croirait à une donnée manquante — donc à un défaut.
  //
  // Il a changé le 31/07/2026 en même temps que la règle qu'il décrit : il
  // annonçait une adresse masquée, alors que c'est désormais l'identité seule
  // qui l'est. Un libellé qui décrit l'ancienne règle est pire que pas de
  // libellé : il fait chercher une adresse qui est déjà à l'écran.
  'fleet.opportunities.masked':
      'Nom et téléphone du destinataire communiqués une fois la course prise.',

  // ── Fiche d'une course ──────────────────────────────────────────────────
  'fleet.detail.title': 'Détail de la course',
  'fleet.detail.not_found': 'Cette course n’est plus disponible.',
  'fleet.detail.section.state': 'La course',
  'fleet.detail.section.money': 'Ce que rapporte cette course',
  'fleet.detail.section.pickup': 'Enlèvement',
  'fleet.detail.section.dropoff': 'Livraison',
  'fleet.detail.section.parcel': 'Colis et contraintes',
  'fleet.detail.contact': 'Contact',
  'fleet.detail.instructions': 'Instructions',
  'fleet.detail.notes': 'Précisions',
  'fleet.detail.order_notes': 'Notes du commerçant',
  'fleet.detail.fragile': 'fragile',
  // Les unités sont traduites comme le reste : « kg » s'écrit « كغ » en arabe,
  // et une unité latine au milieu d'une phrase arabe se lit comme un défaut.
  'fleet.unit.kg': 'kg',
  'fleet.unit.km': 'km',
  'fleet.unit.m': 'm',
  'fleet.detail.items': 'Contenu',
  'fleet.detail.vehicle': 'Véhicule demandé',
  'fleet.detail.distance': 'Distance',
  'fleet.detail.scheduled': 'Prévue pour',
  'fleet.detail.tracking': 'Suivi',
  'fleet.detail.goods': 'Dont marchandise',
  'fleet.detail.pod': 'Preuve de livraison exigée',
  'fleet.detail.address': 'Adresse',
  'fleet.detail.open_map': 'Ouvrir dans une carte',
  'fleet.detail.no_map_app': 'Aucune application de carte sur cet appareil.',

  // ── Conducteurs ─────────────────────────────────────────────────────────
  'fleet.drivers.empty': 'Aucun conducteur rattaché à votre entreprise.',
  'fleet.drivers.add': 'Ajouter un conducteur',
  'fleet.drivers.name': 'Nom',
  'fleet.drivers.email': 'Email',
  'fleet.drivers.phone': 'Téléphone',
  'fleet.drivers.online': 'En ligne',
  'fleet.drivers.offline': 'Hors ligne',
  'fleet.drivers.select': 'Choisir un conducteur',
  'fleet.drivers.name_required': 'Le nom est obligatoire.',
  // ⚠️ Dit la RAISON, pas seulement la règle : sans email ni téléphone, le
  // serveur ne peut ni détecter un doublon ni envoyer l'invitation, donc le
  // conducteur serait créé pour ne jamais servir.
  'fleet.drivers.contact_required':
      'Renseignez un email ou un téléphone — sans quoi ce conducteur ne pourra '
          'jamais recevoir son invitation.',
  // ⚠️ Distinct de `fleet.drivers.empty` : « aucun conducteur » est une
  // affirmation sur l'entreprise, celui-ci un aveu sur nous. Les confondre
  // faisait dire à une entreprise qui a des conducteurs qu'elle n'en a pas.
  'fleet.drivers.unavailable':
      'Impossible de charger vos conducteurs pour le moment.',
  // La consigne dit quoi faire, et surtout ce qu'il ne faut PAS conclure : la
  // liste n'est pas vide, elle est inconnue.
  'fleet.drivers.unavailable.hint':
      'Vos conducteurs sont toujours enregistrés. Réessayez dans un instant.',

  // ── Caisse ──────────────────────────────────────────────────────────────
  // ⚠️ **Ces quatre clés ne sont branchées nulle part.** `CashScreen` est servi
  // en français en dur, comme tous les écrans du dépôt — c'est la dette i18n
  // assumée de `docs/audit_i18n_erreurs.md`, pas un oubli propre à la caisse.
  //
  // Leur formulation, elle, EST employée : le 31/07/2026, l'écran s'est mis à
  // distinguer ce que les conducteurs doivent à l'entreprise de ce qu'elle doit
  // aux commerçants — la lecture que ces clés décrivaient depuis leur création
  // sans que rien ne l'affiche. Elles restent ici pour le jour où l'écran sera
  // traduit ; les retirer perdrait un arabe déjà relu.
  'fleet.cash.title': 'Caisse de l’entreprise',
  'fleet.cash.owed_by_drivers': 'Ce que vos conducteurs vous doivent',
  'fleet.cash.owed_to_merchants': 'Ce que vous devez aux commerçants',
  'fleet.cash.empty': 'Aucun mouvement d’espèces.',

  // ── Rattachements conducteur ↔ entreprise ───────────────────────────────
  'fleet.tab.memberships': 'Rattachements',
  'fleet.members.empty': 'Aucun rattachement.',
  'fleet.members.empty.hint':
      'Cherchez un conducteur déjà dans le réseau, ou créez-en un nouveau.',
  'fleet.members.search': 'Chercher un conducteur',
  'fleet.members.search.hint': 'Nom ou numéro de téléphone',
  'fleet.members.search.none': 'Personne de ce nom dans le réseau.',
  'fleet.members.request': 'Demander le rattachement',
  'fleet.members.requested': 'Demande envoyée. En attente de sa réponse.',
  'fleet.members.origin': 'Votre conducteur',
  // ⚠️ Ce n'est pas un détail d'affichage : un conducteur sans compte ne peut
  // pas répondre, donc la demande resterait en attente indéfiniment et
  // l'entreprise attendrait une réponse qui ne viendra jamais.
  'fleet.members.no_account': 'Pas encore de compte — il ne pourra pas répondre.',
  'fleet.members.create': 'Créer un nouveau conducteur',
  // ⚠️ Le texte explique **pourquoi** on cherche avant de créer : sans lui, un
  // gestionnaire pressé crée un doublon et se demande ensuite pourquoi la
  // position du conducteur ne bouge jamais.
  'fleet.members.create.hint':
      'Cherchez-le d’abord : s’il roule déjà pour quelqu’un, il faut le '
          'rattacher et non le recréer.',
  'fleet.members.suspend': 'Suspendre',
  'fleet.members.reactivate': 'Réactiver',
  'fleet.members.status.pending': 'En attente de sa réponse',
  'fleet.members.status.active': 'Rattaché',
  'fleet.members.status.declined': 'Refusé',
  'fleet.members.status.suspended': 'Suspendu',

  // ── Vu du conducteur ────────────────────────────────────────────────────
  'driver.fleets.title': 'Mes entreprises',
  'driver.fleets.empty': 'Vous n’êtes rattaché à aucune entreprise.',
  'driver.fleets.empty.hint':
      'Une entreprise qui vous embauche vous enverra une demande ici.',
  'driver.fleets.accept': 'Accepter',
  'driver.fleets.decline': 'Refuser',
  'driver.fleets.leave': 'Quitter',
  // ⚠️ Partir coupe les courses à venir, pas ce qu'on doit : le dire évite
  // qu'un conducteur quitte une entreprise en croyant éteindre sa dette.
  'driver.fleets.leave.confirm':
      'Quitter cette entreprise ? Elle ne pourra plus vous confier de course. '
          'Ce que vous lui devez reste dû.',
  // ⚠️ Ce n'est pas une formalité, et l'écran doit le dire : accepter, c'est
  // s'engager à devoir à cette entreprise les espèces qu'on encaissera pour
  // elle.
  'driver.fleets.explain':
      'Accepter, c’est autoriser cette entreprise à vous confier des courses. '
          'Les espèces que vous encaisserez pour elle lui seront dues.',

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
  'fleet.orders.more': 'تحميل الرحلات السابقة',
  'fleet.orders.unassigned': 'لم يتم تعيين سائق',
  'fleet.orders.assign': 'تعيين سائق',
  'fleet.orders.assigned_to': 'السائق',
  'fleet.orders.pickup': 'الاستلام',
  'fleet.orders.dropoff': 'التسليم',
  'fleet.orders.price': 'الأجرة',
  'fleet.orders.cod': 'المبلغ المطلوب عند الباب',
  'fleet.orders.status': 'الحالة',
  'fleet.orders.refresh': 'تحديث',

  'fleet.state.draft': 'لم ينشرها التاجر',
  'fleet.state.broadcast': 'منشورة — في انتظار من يأخذها',
  'fleet.state.taken': 'مأخوذة — لم يُعيَّن سائق',
  'fleet.state.awaiting_start': 'تم تعيين سائق — في انتظار الانطلاق',
  'fleet.state.enroute': 'قيد التوصيل',
  'fleet.state.completed': 'تم التسليم',
  'fleet.state.canceled': 'ملغاة',

  'fleet.opportunities.empty': 'لا توجد رحلات متاحة حالياً.',
  'fleet.opportunities.empty.hint': 'تظهر هنا الرحلات المنشورة وغير المأخوذة بعد.',
  'fleet.opportunities.more': 'تحميل الرحلات التالية',
  'fleet.opportunities.take': 'خذ هذه الرحلة',
  'fleet.opportunities.taking': 'جاري الأخذ…',
  'fleet.opportunities.taken': 'تم أخذ الرحلة. عيّن سائقاً.',
  'fleet.opportunities.masked': 'يُكشف اسم المستلم ورقم هاتفه بعد أخذ الرحلة.',

  'fleet.detail.title': 'تفاصيل الرحلة',
  'fleet.detail.not_found': 'لم تعد هذه الرحلة متاحة.',
  'fleet.detail.section.state': 'الرحلة',
  'fleet.detail.section.money': 'ما تدره هذه الرحلة',
  'fleet.detail.section.pickup': 'الاستلام',
  'fleet.detail.section.dropoff': 'التسليم',
  'fleet.detail.section.parcel': 'الطرد والقيود',
  'fleet.detail.contact': 'جهة الاتصال',
  'fleet.detail.instructions': 'تعليمات',
  'fleet.detail.notes': 'توضيحات',
  'fleet.detail.order_notes': 'ملاحظات التاجر',
  'fleet.detail.fragile': 'قابل للكسر',
  'fleet.unit.kg': 'كغ',
  'fleet.unit.km': 'كم',
  'fleet.unit.m': 'م',
  'fleet.detail.items': 'المحتوى',
  'fleet.detail.vehicle': 'المركبة المطلوبة',
  'fleet.detail.distance': 'المسافة',
  'fleet.detail.scheduled': 'مقررة في',
  'fleet.detail.tracking': 'التتبع',
  'fleet.detail.goods': 'منها قيمة البضاعة',
  'fleet.detail.pod': 'إثبات التسليم مطلوب',
  'fleet.detail.address': 'العنوان',
  'fleet.detail.open_map': 'فتح في الخريطة',
  'fleet.detail.no_map_app': 'لا يوجد تطبيق خرائط على هذا الجهاز.',

  'fleet.drivers.empty': 'لا يوجد سائقون مرتبطون بشركتك.',
  'fleet.drivers.add': 'إضافة سائق',
  'fleet.drivers.name': 'الاسم',
  'fleet.drivers.email': 'البريد الإلكتروني',
  'fleet.drivers.phone': 'الهاتف',
  'fleet.drivers.online': 'متصل',
  'fleet.drivers.offline': 'غير متصل',
  'fleet.drivers.select': 'اختر سائقاً',
  'fleet.drivers.name_required': 'الاسم إلزامي.',
  'fleet.drivers.contact_required':
      'أدخل بريداً إلكترونياً أو رقم هاتف — وإلا لن يتمكن هذا السائق من تلقي دعوته.',
  'fleet.drivers.unavailable': 'تعذّر تحميل قائمة سائقيك حالياً.',
  'fleet.drivers.unavailable.hint':
      'سائقوك ما زالوا مسجّلين. أعد المحاولة بعد قليل.',

  'fleet.cash.title': 'صندوق الشركة',
  'fleet.cash.owed_by_drivers': 'ما يدين به سائقوك لك',
  'fleet.cash.owed_to_merchants': 'ما تدين به للتجار',
  'fleet.cash.empty': 'لا توجد حركات نقدية.',

  'fleet.tab.memberships': 'الارتباطات',
  'fleet.members.empty': 'لا توجد ارتباطات.',
  'fleet.members.empty.hint': 'ابحث عن سائق موجود في الشبكة، أو أنشئ سائقاً جديداً.',
  'fleet.members.search': 'البحث عن سائق',
  'fleet.members.search.hint': 'الاسم أو رقم الهاتف',
  'fleet.members.search.none': 'لا أحد بهذا الاسم في الشبكة.',
  'fleet.members.request': 'طلب الارتباط',
  'fleet.members.requested': 'تم إرسال الطلب. في انتظار رده.',
  'fleet.members.origin': 'سائقك',
  'fleet.members.no_account': 'لا يملك حساباً بعد — لن يتمكن من الرد.',
  'fleet.members.create': 'إنشاء سائق جديد',
  'fleet.members.create.hint':
      'ابحث عنه أولاً: إذا كان يعمل لدى جهة أخرى، يجب ربطه لا إنشاؤه من جديد.',
  'fleet.members.suspend': 'تعليق',
  'fleet.members.reactivate': 'إعادة التفعيل',
  'fleet.members.status.pending': 'في انتظار رده',
  'fleet.members.status.active': 'مرتبط',
  'fleet.members.status.declined': 'مرفوض',
  'fleet.members.status.suspended': 'معلّق',

  'driver.fleets.title': 'شركاتي',
  'driver.fleets.empty': 'لست مرتبطاً بأي شركة.',
  'driver.fleets.empty.hint': 'الشركة التي توظفك سترسل لك طلباً هنا.',
  'driver.fleets.accept': 'قبول',
  'driver.fleets.decline': 'رفض',
  'driver.fleets.leave': 'مغادرة',
  'driver.fleets.leave.confirm':
      'مغادرة هذه الشركة؟ لن تتمكن من إسناد رحلات إليك. ما تدين به لها يبقى مستحقاً.',
  'driver.fleets.explain':
      'القبول يعني السماح لهذه الشركة بإسناد رحلات إليك. الأموال التي تحصّلها '
          'لصالحها تصبح ديناً عليك تجاهها.',

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
