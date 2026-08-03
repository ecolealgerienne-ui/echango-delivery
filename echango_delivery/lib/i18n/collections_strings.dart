import 'dart:ui' show Locale;

import 'translate.dart';

/// Libellés de l'écran « encaissements » du commerçant, dans les deux langues.
///
/// ── Ce qui a remplacé quoi ─────────────────────────────────────────────────
///
/// `cash_strings.dart` portait ~105 chaînes servant l'écran de caisse des trois
/// profils : soldes, dettes, remises, confirmations, contestations. L'écran est
/// retiré depuis le 03/08/2026 (`docs/registre_caisse_precis.md`) ; il en reste
/// une lecture pour le seul commerçant, et une trentaine de libellés.
///
/// L'argument qui avait fait traduire cet écran **avant les autres** vaut
/// toujours, et il vaut même davantage maintenant : c'est celui où il est
/// question d'argent. « Modifier » mal traduit se devine ; « ce transporteur
/// a perçu 2 700 au lieu de 2 727 » ne se devine pas.
///
/// ⚠️ Les motifs d'écart sont des **codes** venus du serveur
/// (`COLLECTION_DISCREPANCY_REASONS`) et traduits ici. Le serveur ne rédige
/// jamais le motif : il serait en français pour un arabophone (règle 4).
String collectionsLabel(String key, Locale locale, [Map<String, String>? vars]) =>
    translate(_fr, _ar, key, locale, vars);

const Map<String, Map<String, String>> collectionsLabelTables = {'fr': _fr, 'ar': _ar};

/// Les motifs d'écart, **dans l'ordre où on les propose au transporteur**.
///
/// ⚠️ **Copie de `COLLECTION_DISCREPANCY_REASONS`**
/// (`backend/bff/src/common/money/collection.ts`), reproduite ici parce que le
/// sélecteur ne peut pas attendre un aller-retour réseau à la porte du client.
/// Un code absent de la liste serveur est refusé en 400 : si l'une change,
/// l'autre doit changer (règle 7).
///
/// Une liste de codes et une fonction de libellé, jamais une map : le code part
/// au serveur et sera compté, le libellé est de la langue. Les mêler ferait
/// itérer sur du français pour construire un sélecteur.
const List<String> collectionDiscrepancyReasons = <String>[
  'somme_incomplete',
  'refus_de_payer',
  'pas_de_monnaie',
  'montant_conteste',
  'autre',
];

/// Le libellé d'un motif d'écart, ou [fallback] quand le code est inconnu.
///
/// Un code venu du serveur mais absent de la liste ne doit pas s'afficher tel
/// quel (`somme_incomplete` ne se lit pas), ni disparaître : l'appelant décide
/// de ce qui le remplace.
String collectionReasonLabel(String? code, Locale locale, {required String fallback}) {
  if (code == null || !collectionDiscrepancyReasons.contains(code)) return fallback;
  return collectionsLabel('collections.reason.$code', locale);
}

const Map<String, String> _fr = {
  'collections.title': 'Encaissements',

  // ── Ce que la plateforme fait, et ne fait pas ────────────────────────────
  //
  // Dit une fois, en tête. Sans cette phrase, un commerçant peut croire que
  // l'application suit ce qu'on lui doit — et attendre d'elle un recouvrement
  // qu'elle ne fait pas.
  'collections.disclaimer':
      'Echango ne détient jamais cet argent et ne tient pas le compte de ce '
      'qui vous est dû. Cette page montre ce qui a été déclaré à chaque porte ; '
      'le règlement se fait entre vous et votre transporteur.',

  'collections.section.expected': 'En route — pas encore perçu',
  'collections.section.collected': 'Perçu à la porte',
  'collections.section.unrecorded': 'Livrées sans déclaration',

  'collections.total.expected': 'À encaisser aux portes : {amount} {currency}',
  'collections.total.collected': 'Déclaré perçu : {amount} {currency}',
  'collections.total.unrecorded': 'Annoncé sur ces livraisons : {amount} {currency}',

  'collections.hint.expected':
      'Ces livraisons sont en cours. Cet argent n’est encore dans la poche de '
      'personne.',
  'collections.hint.collected':
      'Ce que le transporteur a déclaré avoir reçu en clôturant la livraison.',
  'collections.hint.unrecorded':
      'Terminées avec un montant à encaisser, mais aucune déclaration. Le cas '
      'habituel est une clôture faite hors application. Le montant affiché est '
      'celui qui était annoncé — nous ignorons ce qui a réellement été perçu.',

  'collections.line.delivery': 'Livraison',
  'collections.line.driver': 'Par {name}',
  'collections.line.driver.unknown': 'Transporteur non renseigné',
  'collections.line.expected': 'Annoncé : {amount}',
  'collections.line.collected': 'Perçu : {amount}',
  'collections.line.collected.at': 'Déclaré le {date}',
  'collections.line.discrepancy': 'Écart de {amount} — {reason}',
  'collections.line.nothing_collected': 'Rien n’a été perçu — {reason}',
  'collections.line.unknown_amount': '—',

  // Motifs d'écart : la liste fermée du serveur.
  'collections.reason.somme_incomplete': 'le client n’avait pas la totalité',
  'collections.reason.refus_de_payer': 'le client a refusé de payer',
  'collections.reason.pas_de_monnaie': 'personne n’avait de monnaie',
  'collections.reason.montant_conteste': 'le montant était contesté',
  'collections.reason.autre': 'autre motif',

  'collections.empty.title': 'Aucun encaissement à afficher',
  'collections.empty.hint':
      'Vos livraisons payées à la réception apparaîtront ici, avant et après '
      'le passage du transporteur.',
  'collections.unavailable.title': 'Encaissements indisponibles',
  'collections.unavailable.hint':
      'Impossible de lire vos livraisons pour le moment. Réessayez dans un '
      'instant.',
  'collections.retry': 'Réessayer',
};

const Map<String, String> _ar = {
  'collections.title': 'المبالغ المحصَّلة',

  'collections.disclaimer':
      'إيشانغو لا تحتفظ بهذه الأموال ولا تمسك حساب ما هو مستحق لك. تعرض هذه '
      'الصفحة ما صُرِّح به عند كل باب؛ أمّا التسوية فتتم بينك وبين الناقل.',

  'collections.section.expected': 'في الطريق — لم تُقبض بعد',
  'collections.section.collected': 'قُبضت عند الباب',
  'collections.section.unrecorded': 'سُلِّمت دون تصريح',

  'collections.total.expected': 'للتحصيل عند الأبواب: {amount} {currency}',
  'collections.total.collected': 'صُرِّح بقبضه: {amount} {currency}',
  'collections.total.unrecorded': 'المعلَن على عمليات التسليم هذه: {amount} {currency}',

  'collections.hint.expected':
      'عمليات التسليم هذه جارية. هذا المال ليس بعدُ في جيب أحد.',
  'collections.hint.collected':
      'ما صرَّح الناقل بأنه تسلَّمه عند إنهاء عملية التسليم.',
  'collections.hint.unrecorded':
      'انتهت وعليها مبلغ للتحصيل، لكن دون أي تصريح. الحالة المعتادة هي إنهاء تم '
      'خارج التطبيق. المبلغ المعروض هو المبلغ المعلَن — فنحن نجهل ما قُبض فعلاً.',

  'collections.line.delivery': 'عملية تسليم',
  'collections.line.driver': 'بواسطة {name}',
  'collections.line.driver.unknown': 'الناقل غير محدَّد',
  'collections.line.expected': 'المعلَن: {amount}',
  'collections.line.collected': 'المقبوض: {amount}',
  'collections.line.collected.at': 'صُرِّح به في {date}',
  'collections.line.discrepancy': 'فارق قدره {amount} — {reason}',
  'collections.line.nothing_collected': 'لم يُقبض أي شيء — {reason}',
  'collections.line.unknown_amount': '—',

  'collections.reason.somme_incomplete': 'لم يكن لدى الزبون المبلغ كاملاً',
  'collections.reason.refus_de_payer': 'رفض الزبون الدفع',
  'collections.reason.pas_de_monnaie': 'لم يكن لدى أحد صرف',
  'collections.reason.montant_conteste': 'كان المبلغ محل نزاع',
  'collections.reason.autre': 'سبب آخر',

  'collections.empty.title': 'لا توجد مبالغ محصَّلة لعرضها',
  'collections.empty.hint':
      'ستظهر هنا عمليات التسليم المدفوعة عند الاستلام، قبل مرور الناقل وبعده.',
  'collections.unavailable.title': 'المبالغ المحصَّلة غير متاحة',
  'collections.unavailable.hint':
      'تعذّرت قراءة عمليات التسليم الآن. أعد المحاولة بعد لحظات.',
  'collections.retry': 'إعادة المحاولة',
};
