import 'dart:ui' show Locale;

/// Libellés du formulaire de demande de livraison (commerçant).
///
/// ── Pourquoi cet écran en premier ─────────────────────────────────────────
///
/// C'est le plus gros du lot (85 chaînes visibles) et **c'est là qu'on saisit
/// ce qui engage de l'argent** : le montant réclamé au destinataire, la
/// rémunération du transporteur, et qui paie la livraison. Un commerçant
/// arabophone lisait ici, en français, la différence entre « Montant à
/// encaisser » et « Prix de la marchandise » — deux intitulés qui ne désignent
/// le même nombre que dans un cas sur deux, et dont la confusion se constate à
/// la porte, en espèces.
///
/// ── Le mécanisme, repris de `cash_strings.dart` ──────────────────────────
///
/// Deux tables, une par langue, clés strictement identiques
/// (`tool/check_error_codes.dart` le vérifie), et des `{variable}` plutôt que
/// des concaténations : l'ordre des mots change d'une langue à l'autre, et
/// surtout **la conversion se prouve** — chaque chaîne retirée de l'écran doit
/// se retrouver dans la table, placeholders resubstitués. C'est la seule façon
/// de relire quatre-vingts remplacements sans analyseur.
///
/// Un libellé manquant retombe sur sa clé plutôt que sur du français brut : une
/// clé à l'écran est laide et se corrige, une phrase française au milieu d'un
/// écran arabe passe pour un défaut de l'application.
///
/// ⚠️ **Ce qui n'est PAS ici, et ne doit pas y venir** : `'Commerce'`, le repli
/// de `pickupContactName` à la création. Ce n'est pas un libellé, c'est une
/// **donnée** envoyée au serveur, stockée chez Fleetbase et relue par le
/// transporteur. La traduire ferait dépendre le contenu de la base de la langue
/// du téléphone qui a créé la commande, et un même commerçant produirait des
/// contacts nommés tantôt « Commerce », tantôt « متجر ».
///
/// ⚠️ **L'arabe est de ma main et n'a pas été relu par un locuteur.** Les
/// pluriels sont approximatifs (« favori(s) » n'a pas d'équivalent direct), et
/// le vocabulaire monétaire mériterait une passe. Le dire ici plutôt que
/// laisser croire à une traduction validée.
String orderFormLabel(String key, Locale locale, [Map<String, String>? vars]) {
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
const Map<String, Map<String, String>> orderFormLabelTables = {
  'fr': _fr,
  'ar': _ar,
};

const Map<String, String> _fr = {
  // ── Titres et sections ──────────────────────────────────────────────────
  'order.form.title.new': 'Nouvelle livraison',
  'order.form.title.duplicate': 'Reprendre une livraison',
  'order.form.section.pickup': 'Retrait',
  'order.form.section.dropoff': 'Livraison',
  'order.form.section.parcel': 'Colis',
  'order.form.section.options': 'Options',

  // ── Champs ──────────────────────────────────────────────────────────────
  'order.form.pickup.name': 'Lieu de retrait *',
  'order.form.pickup.contact': 'Contact sur place',
  'order.form.dropoff.name': 'Destinataire *',
  'order.form.dropoff.contact': 'Contact (si différent)',
  // Partagés par les deux points : le même mot pour la même chose, sinon deux
  // clés à tenir accordées pour rien.
  'order.form.address': 'Adresse',
  'order.form.phone': 'Téléphone *',

  // ── Colis ───────────────────────────────────────────────────────────────
  'order.form.item.description': 'Contenu (ex. : gâteau, médicaments)',
  'order.form.item.quantity': 'Nombre de colis',
  'order.form.item.weight': 'Poids approximatif (kg)',
  'order.form.item.fragile': 'Contenu fragile',
  'order.form.item.fragile.hint':
      'Signalé au transporteur avant qu’il accepte la course.',

  // ── Position ────────────────────────────────────────────────────────────
  'order.form.location.book': 'Carnet',
  'order.form.location.pick': 'Placer sur la carte',
  'order.form.location.edit': 'Modifier le point',
  'order.form.location.unset': 'Position non définie',
  'order.form.location.set': 'Position définie ({lat}, {lng})',
  'order.form.map.pickup': 'Point de retrait',
  'order.form.map.dropoff': 'Point de livraison',

  // ── Véhicule ────────────────────────────────────────────────────────────
  'order.form.vehicle.label': 'Véhicule nécessaire',
  'order.form.vehicle.any': 'Indifférent',
  'order.form.vehicle.moto': 'Moto minimum',
  'order.form.vehicle.voiture': 'Voiture minimum',
  'order.form.vehicle.utilitaire': 'Utilitaire requis',

  // ── Tarification ────────────────────────────────────────────────────────
  'order.form.price.label': 'Rémunération proposée (DZD)',
  'order.form.price.hint':
      'Ce montant est affiché aux transporteurs : c’est sur lui qu’ils '
          'décident de prendre la course.',
  'order.form.price.hint.distance':
      'Distance estimée : {distance}. Ce montant est affiché aux transporteurs.',
  'order.form.quote.flat': 'Tarif Echango pour cette course',
  'order.form.quote.distance': 'Tarif Echango — {distance}',

  // ── Paiement à la livraison ─────────────────────────────────────────────
  'order.form.cod.enable': 'Le client paie à la livraison',
  'order.form.cod.enable.hint':
      'Le transporteur encaisse et vous remet la somme lors de son prochain '
          'passage. Echango ne détient jamais cet argent.',
  'order.form.cod.amount.total': 'Montant à encaisser (DZD)',
  'order.form.cod.amount.goods': 'Prix de la marchandise (DZD)',
  'order.form.cod.included': 'Les frais de livraison sont inclus',
  'order.form.cod.included.hint':
      'Le client règle la marchandise et la livraison en une fois.',
  'order.form.cod.excluded.hint':
      'Les frais de livraison sont réclamés au client en plus de la marchandise.',
  'order.form.cod.total.included': 'Le destinataire remettra {amount} DZD.',
  'order.form.cod.total.missing_fee':
      'Indiquez la rémunération du transporteur : elle sera réclamée au '
          'destinataire en plus de la marchandise.',
  'order.form.cod.total.excluded':
      'Le destinataire remettra {total} DZD ({goods} de marchandise + {fee} '
          'de livraison).',
  'order.form.cod.settlement':
      'Le transporteur retient sa rémunération sur les espèces et ne vous '
          'remet que la différence, lors de son prochain passage.',

  // ── Enlèvement ──────────────────────────────────────────────────────────
  'order.form.schedule.title': 'Enlèvement',
  'order.form.schedule.asap': 'Dès que possible',
  'order.form.schedule.clear': 'Revenir à « dès que possible »',

  // ── Preuve de livraison ─────────────────────────────────────────────────
  'order.form.pod.label': 'Preuve de livraison',
  'order.form.pod.photo': 'Photo à la livraison',
  'order.form.pod.none': 'Aucune preuve',

  // ── Favoris ─────────────────────────────────────────────────────────────
  'order.form.favourites.title':
      'Proposer d’abord à mes transporteurs habituels',
  'order.form.favourites.hint':
      '{count} favori(s). Si aucun n’est disponible, la course est proposée à '
          'l’ensemble du réseau.',

  // ── Instructions, brouillon, envoi ──────────────────────────────────────
  'order.form.instructions': 'Instructions pour le transporteur',
  'order.form.draft.notice':
      'Cette livraison est enregistrée en brouillon : aucun transporteur n’est '
          'sollicité tant que vous ne l’avez pas publiée depuis sa fiche.',
  'order.form.submit': 'Enregistrer en brouillon',

  // ── Carnet d'adresses (feuille) ─────────────────────────────────────────
  'order.form.book.search': 'Rechercher dans le carnet…',
  'order.form.book.empty': 'Aucune adresse ne correspond',

  // ── Messages ────────────────────────────────────────────────────────────
  'order.form.address.no_position':
      '« {name} » n’a pas de position enregistrée : placez-la sur la carte '
          'pour continuer.',
  'order.form.missing': 'Il manque {fields}',
  // Le séparateur est dans la table : l'arabe emploie sa propre virgule (،),
  // et un `', '` en dur produirait une énumération à la française au milieu
  // d'une phrase arabe.
  'order.form.missing.separator': ', ',
  'order.form.missing.pickup_name': 'le lieu de retrait',
  'order.form.missing.pickup_phone': 'le téléphone de retrait',
  'order.form.missing.dropoff_name': 'le nom du destinataire',
  'order.form.missing.dropoff_phone': 'le téléphone du destinataire',
  'order.form.missing.pickup_point': 'le point de retrait sur la carte',
  'order.form.missing.dropoff_point': 'le point de livraison sur la carte',
  'order.form.saved':
      'Brouillon enregistré. Relisez-le puis publiez-le pour trouver un '
          'transporteur.',
  'order.form.failed': 'Création impossible',
};

const Map<String, String> _ar = {
  // ── Titres et sections ──────────────────────────────────────────────────
  'order.form.title.new': 'توصيل جديد',
  'order.form.title.duplicate': 'إعادة توصيل سابق',
  'order.form.section.pickup': 'الاستلام',
  'order.form.section.dropoff': 'التسليم',
  'order.form.section.parcel': 'الطرد',
  'order.form.section.options': 'خيارات',

  // ── Champs ──────────────────────────────────────────────────────────────
  'order.form.pickup.name': 'مكان الاستلام *',
  'order.form.pickup.contact': 'جهة الاتصال في المكان',
  'order.form.dropoff.name': 'المرسل إليه *',
  'order.form.dropoff.contact': 'جهة اتصال أخرى (إن وجدت)',
  'order.form.address': 'العنوان',
  'order.form.phone': 'الهاتف *',

  // ── Colis ───────────────────────────────────────────────────────────────
  'order.form.item.description': 'المحتوى (مثال: كعك، أدوية)',
  'order.form.item.quantity': 'عدد الطرود',
  'order.form.item.weight': 'الوزن التقريبي (كغ)',
  'order.form.item.fragile': 'محتوى قابل للكسر',
  'order.form.item.fragile.hint': 'يُعلَم الناقل قبل قبوله المهمة.',

  // ── Position ────────────────────────────────────────────────────────────
  'order.form.location.book': 'الدفتر',
  'order.form.location.pick': 'تحديد على الخريطة',
  'order.form.location.edit': 'تعديل النقطة',
  'order.form.location.unset': 'الموقع غير محدد',
  'order.form.location.set': 'الموقع محدد ({lat}، {lng})',
  'order.form.map.pickup': 'نقطة الاستلام',
  'order.form.map.dropoff': 'نقطة التسليم',

  // ── Véhicule ────────────────────────────────────────────────────────────
  'order.form.vehicle.label': 'المركبة المطلوبة',
  'order.form.vehicle.any': 'لا يهم',
  'order.form.vehicle.moto': 'دراجة نارية على الأقل',
  'order.form.vehicle.voiture': 'سيارة على الأقل',
  'order.form.vehicle.utilitaire': 'شاحنة صغيرة إلزامية',

  // ── Tarification ────────────────────────────────────────────────────────
  'order.form.price.label': 'الأجر المقترح (دج)',
  'order.form.price.hint':
      'هذا المبلغ يظهر للناقلين: على أساسه يقررون قبول المهمة.',
  'order.form.price.hint.distance':
      'المسافة التقريبية: {distance}. هذا المبلغ يظهر للناقلين.',
  'order.form.quote.flat': 'تسعيرة Echango لهذه المهمة',
  'order.form.quote.distance': 'تسعيرة Echango — {distance}',

  // ── Paiement à la livraison ─────────────────────────────────────────────
  'order.form.cod.enable': 'الزبون يدفع عند التسليم',
  'order.form.cod.enable.hint':
      'الناقل يقبض المبلغ ويسلّمه لك عند مروره القادم. Echango لا تحتفظ بهذا '
          'المال أبدًا.',
  'order.form.cod.amount.total': 'المبلغ المطلوب تحصيله (دج)',
  'order.form.cod.amount.goods': 'ثمن البضاعة (دج)',
  'order.form.cod.included': 'رسوم التوصيل مشمولة',
  'order.form.cod.included.hint': 'الزبون يدفع البضاعة والتوصيل دفعة واحدة.',
  'order.form.cod.excluded.hint':
      'رسوم التوصيل تُطلب من الزبون زيادة على ثمن البضاعة.',
  'order.form.cod.total.included': 'سيدفع المرسل إليه {amount} دج.',
  'order.form.cod.total.missing_fee':
      'حدّد أجر الناقل: سيُطلب من المرسل إليه زيادة على ثمن البضاعة.',
  'order.form.cod.total.excluded':
      'سيدفع المرسل إليه {total} دج ({goods} ثمن البضاعة + {fee} رسوم '
          'التوصيل).',
  'order.form.cod.settlement':
      'يقتطع الناقل أجره من المبلغ المحصَّل ولا يسلّمك سوى الفرق، عند مروره '
          'القادم.',

  // ── Enlèvement ──────────────────────────────────────────────────────────
  'order.form.schedule.title': 'الاستلام',
  'order.form.schedule.asap': 'في أقرب وقت',
  'order.form.schedule.clear': 'العودة إلى «في أقرب وقت»',

  // ── Preuve de livraison ─────────────────────────────────────────────────
  'order.form.pod.label': 'إثبات التسليم',
  'order.form.pod.photo': 'صورة عند التسليم',
  'order.form.pod.none': 'بدون إثبات',

  // ── Favoris ─────────────────────────────────────────────────────────────
  'order.form.favourites.title': 'اقتراحها أولًا على ناقليّ المعتادين',
  'order.form.favourites.hint':
      '{count} مفضّل. إذا لم يتوفر أحد منهم، تُعرض المهمة على كامل الشبكة.',

  // ── Instructions, brouillon, envoi ──────────────────────────────────────
  'order.form.instructions': 'تعليمات للناقل',
  'order.form.draft.notice':
      'هذا التوصيل مسجَّل كمسودة: لا يُطلب أي ناقل ما دمت لم تنشره من بطاقته.',
  'order.form.submit': 'حفظ كمسودة',

  // ── Carnet d'adresses (feuille) ─────────────────────────────────────────
  'order.form.book.search': 'البحث في الدفتر…',
  'order.form.book.empty': 'لا يوجد عنوان مطابق',

  // ── Messages ────────────────────────────────────────────────────────────
  'order.form.address.no_position':
      '«{name}» ليس له موقع مسجَّل: حدّده على الخريطة للمتابعة.',
  'order.form.missing': 'ينقص {fields}',
  'order.form.missing.separator': '، ',
  'order.form.missing.pickup_name': 'مكان الاستلام',
  'order.form.missing.pickup_phone': 'هاتف الاستلام',
  'order.form.missing.dropoff_name': 'اسم المرسل إليه',
  'order.form.missing.dropoff_phone': 'هاتف المرسل إليه',
  'order.form.missing.pickup_point': 'نقطة الاستلام على الخريطة',
  'order.form.missing.dropoff_point': 'نقطة التسليم على الخريطة',
  'order.form.saved':
      'حُفظت المسودة. راجعها ثم انشرها للعثور على ناقل.',
  'order.form.failed': 'تعذّر الإنشاء',
};
