import 'dart:ui' show Locale;

import 'translate.dart';

/// Libellés du registre de caisse, dans les deux langues.
///
/// ── Pourquoi cet écran-ci, avant les autres ───────────────────────────────
///
/// Parce que c'est **celui où il est question d'argent**. Les ~575 chaînes
/// françaises en dur du dépôt sont une dette assumée (`docs/audit_i18n_erreurs.md`),
/// mais elles ne se valent pas : « Modifier » mal traduit se devine, « Vous
/// devez cette somme à ce transporteur » non. Un gestionnaire arabophone lisait
/// ici, en français, qui doit quoi à qui — et le sens d'une dette est
/// exactement ce qu'on ne peut pas deviner.
///
/// C'était aussi le plus gros bloc d'un seul écran : ~105 chaînes visibles,
/// servies aux trois profils.
///
/// ── La substitution, et pourquoi elle rend la conversion vérifiable ───────
///
/// Les libellés portent des `{variable}` plutôt que d'être découpés en
/// morceaux à concaténer. Deux raisons, et la seconde est la vraie :
///
///  1. **L'ordre des mots change d'une langue à l'autre.** Concaténer
///     « Maximum » + le nombre fige l'ordre français ; `{amount}` laisse chaque
///     table le placer où sa langue le met.
///  2. **La conversion se prouve.** Chaque chaîne retirée de l'écran doit se
///     retrouver ici, placeholders resubstitués — c'est la même preuve par
///     inversion que le lot des jetons d'espacement, et c'est la seule façon de
///     relire cinquante remplacements sans analyseur.
///
/// ── Le pluriel ────────────────────────────────────────────────────────────
///
/// Deux formes seulement (`.one` / `.many`), choisies par l'appelant. C'est
/// juste en français et **approximatif en arabe**, qui distingue le duel et
/// plusieurs pluriels. Le dire plutôt que de laisser croire à une gestion
/// complète : la forme retenue est celle du pluriel courant, lisible dans tous
/// les cas, et un vrai pluriel arabe demanderait `intl` et sa génération — que
/// ce dépôt ne peut pas exécuter (même motif que `fleet_strings.dart`).
///
/// ⚠️ Conséquence à ne pas « corriger » : deux clés `.one` portent `{count}` en
/// français et pas en arabe, où le singulier se dit sans le chiffre (« عملية
/// تسليم واحدة »). Un vérificateur qui exigerait les mêmes variables des deux
/// côtés signalerait ici un écart qui est la traduction juste.
///
/// ── Une clé manquante retombe sur elle-même ───────────────────────────────
///
/// Jamais sur du français brut : une clé à l'écran est laide et se corrige, une
/// phrase française au milieu d'un écran arabe passe pour un défaut de
/// l'application.
String cashLabel(String key, Locale locale, [Map<String, String>? vars]) =>
    translate(_fr, _ar, key, locale, vars);

/// Les deux tables, exposées pour le vérificateur de clés.
const Map<String, Map<String, String>> cashLabelTables = {'fr': _fr, 'ar': _ar};

const Map<String, String> _fr = {
  // ── Titres ──────────────────────────────────────────────────────────────
  'cash.title.driver': 'Ma caisse',
  'cash.title.fleet': 'Caisse de l’entreprise',
  'cash.title.merchant': 'Encaissements',

  // ── Sections ────────────────────────────────────────────────────────────
  'cash.section.collections_to_confirm': 'Encaissements à confirmer',
  'cash.section.to_confirm': 'À confirmer',
  // « Mes transporteurs » est faux pour une entreprise : sa liste mêle ses
  // conducteurs et les commerçants qu'elle sert.
  'cash.section.accounts': 'Mes comptes',
  'cash.section.carriers': 'Mes transporteurs',
  'cash.section.pending': 'En cours — pas encore encaissé',
  'cash.section.collections': 'Détail des encaissements',
  'cash.section.awaiting_other': 'En attente de l’autre partie',
  'cash.collections.preview':
      '{count} dernières livraisons encaissées sur {total}.',

  // ── En attente de l'autre partie ────────────────────────────────────────
  'cash.awaiting.driver': 'Le commerçant n’a pas encore confirmé la réception.',
  // `CashRemittance` ne porte pas le type de la contrepartie : une entreprise
  // remet à un commerçant et reçoit d'un conducteur, et on ne peut pas dire
  // lequel ici. On reste neutre plutôt que de deviner.
  'cash.awaiting.fleet': 'L’autre partie n’a pas encore confirmé.',
  'cash.awaiting.merchant': 'Le transporteur n’a pas encore confirmé.',

  // ── Le total ────────────────────────────────────────────────────────────
  'cash.total.owed_by_drivers': 'Ce que vos conducteurs vous doivent',
  'cash.total.collected_for_you': 'Espèces encaissées pour vous',
  'cash.total.owed_to_merchants': 'Ce que vous devez aux commerçants',
  'cash.total.you_hold': 'Espèces que vous détenez',
  'cash.total.position': 'Position totale',
  'cash.total.note.both':
      'Ce que vous détenez est à remettre à chaque commerçant, ce que vos '
          'conducteurs détiennent vous revient à leur prochain passage. Echango '
          'ne détient jamais cet argent.',
  'cash.total.note.driver':
      'Votre rémunération est déjà déduite. Le reste est à remettre à chaque '
          'commerçant lors de votre prochain enlèvement chez lui. Echango ne '
          'détient jamais cet argent.',
  'cash.total.note.merchant':
      'Détenues par vos transporteurs, rémunération déduite, jusqu’à leur '
          'prochain passage. Echango ne détient jamais cet argent.',
  'cash.expected.total': 'À encaisser aux portes : {amount} {currency}',
  'cash.expected.count.one':
      '{count} livraison en cours. Cet argent n’a pas encore été perçu.',
  'cash.expected.count.many':
      '{count} livraisons en cours. Cet argent n’a pas encore été perçu.',
  'cash.commission.total': 'Commission Echango cumulée : {amount} {currency}',
  'cash.commission.note':
      'Déjà prélevée sur vos courses. Facturée séparément par Echango, pas '
          'depuis cette application.',

  // ── Absences ────────────────────────────────────────────────────────────
  'cash.empty.fleet.title': 'Aucun mouvement d’espèces',
  'cash.empty.fleet.hint':
      'Ce que vos conducteurs encaissent apparaîtra ici, avec ce que vous devez '
          'reverser à chaque commerçant.',
  'cash.empty.driver.title': 'Vous ne détenez aucune somme',
  'cash.empty.driver.hint':
      'Les encaissements que vous déclarez à la livraison apparaîtront ici, '
          'avec ce que vous devez à chaque commerçant.',
  'cash.empty.unrecorded.title': 'Aucun solde ouvert',
  'cash.empty.unrecorded.hint':
      'Mais des livraisons closes hors application n’ont laissé aucun '
          'encaissement : régularisez-les depuis l’alerte ci-dessus.',
  'cash.empty.pending.title': 'Rien à récupérer pour l’instant',
  'cash.empty.pending.hint':
      'Les livraisons en cours ne sont pas encore encaissées : la somme '
          'apparaîtra à la remise du colis.',
  'cash.empty.none.title': 'Aucune somme en attente',
  'cash.empty.none.hint':
      'Vous verrez ici ce que chaque transporteur vous doit, dès qu’une '
          'livraison sera encaissée à la porte.',

  // ── Déclarer, confirmer, contester ──────────────────────────────────────
  'cash.declare.title': 'Enregistrer un versement',
  'cash.declare.subtitle':
      'Avec {name}. La somme ne sera déduite qu’après confirmation par l’autre '
          'partie.',
  'cash.declare.failed': 'Déclaration impossible',
  'cash.declare.done': 'Remise déclarée. Elle sera déduite après confirmation.',
  'cash.confirm.failed': 'Confirmation impossible',
  'cash.confirm.done': 'Remise confirmée — {amount} déduits.',
  'cash.regularise.title': 'Déclarer l’encaissement',
  'cash.regularise.subtitle.named':
      '{name} a encaissé combien sur cette livraison ? Il devra confirmer avant '
          'que la somme ne soit comptée.',
  'cash.regularise.subtitle.anon':
      'Combien a été encaissé sur cette livraison ? Le transporteur devra '
          'confirmer avant que la somme ne soit comptée.',
  'cash.regularise.done': 'Déclaré. En attente de confirmation du transporteur.',
  'cash.collection.confirm.done':
      'Encaissement confirmé — il entre dans votre caisse.',
  'cash.collection.dispute.title': 'Contester cet encaissement ?',
  'cash.collection.dispute.body':
      'Vous déclarez ne pas avoir encaissé {amount} {currency} sur cette '
          'livraison. Rien ne sera compté et Echango sera alerté.',
  'cash.collection.dispute.done': 'Encaissement contesté.',
  'cash.dispute.failed': 'Contestation impossible',
  'cash.remittance.dispute.title': 'Contester cette remise ?',
  'cash.remittance.dispute.body':
      'Vous déclarez ne pas avoir reçu {amount}. La somme reste due et Echango '
          'sera alerté.',
  'cash.remittance.dispute.done': 'Remise contestée. La somme reste due.',
  'cash.discrepancy.why': 'Pourquoi ce montant diffère ?',

  // ── Boutons ─────────────────────────────────────────────────────────────
  'cash.action.back': 'Retour',
  'cash.action.dispute': 'Contester',
  'cash.action.confirm': 'Confirmer',
  'cash.action.cancel': 'Annuler',
  'cash.action.validate': 'Valider',
  'cash.action.call': 'Appeler',
  'cash.action.received_nothing': 'Je n’ai rien reçu',
  'cash.action.remitted': 'J’ai remis',
  'cash.action.received': 'J’ai reçu',

  // ── Le sens d'un solde ──────────────────────────────────────────────────
  // Un montant nu sur un solde signé se lit dans le mauvais sens une fois sur
  // deux : la phrase dit qui doit à qui, et elle n'est pas décorative.
  'cash.sense.held_by': 'Détenue par {who}.',
  'cash.sense.you_owe': 'Vous devez cette somme à {who}.',
  'cash.sense.you_hold': 'Vous détenez cette somme pour {who}.',
  'cash.sense.owes_you':
      '{who} vous doit cette somme (course non couverte par l’encaissement).',
  'cash.sense.upstream_unknown': 'Somme détenue en amont, en attente de remise.',
  'cash.sense.reverse_unknown': 'Somme due en sens inverse.',
  'cash.blocked.driver':
      'Plafond atteint : plus de course encaissée pour ce commerçant avant '
          'votre remise.',
  'cash.blocked.other': 'Plafond atteint pour {who}.',
  'cash.account.unnamed': 'Compte {id}',

  // ── Qui a déclaré la remise ─────────────────────────────────────────────
  'cash.declared_by.driver':
      'Le transporteur déclare vous avoir remis cette somme.',
  'cash.declared_by.fleet':
      'L’entreprise de transport déclare vous avoir remis cette somme.',
  'cash.declared_by.merchant':
      'Le commerçant déclare vous avoir remis cette somme.',
  'cash.declared_by.unknown':
      'L’autre partie déclare vous avoir remis cette somme.',

  // ── Saisie d'un montant ─────────────────────────────────────────────────
  'cash.amount.label': 'Montant ({currency})',
  'cash.amount.max': 'Maximum {amount}',

  // ── Décomposition d'un encaissement ─────────────────────────────────────
  'cash.line.collected': 'Perçu du destinataire',
  'cash.line.retained.driver': 'Votre rémunération retenue',
  'cash.line.retained.other': 'Retenu par le transporteur',
  'cash.line.net.driver': 'Reste à remettre',
  'cash.line.net.fleet': 'À remettre au commerçant',
  'cash.line.net.merchant': 'Vous revient',
  'cash.discrepancy.line': '{reason} — {amount} étaient attendus.',
  'cash.discrepancy.default': 'Écart signalé',

  // ── Livraisons attendues et anomalies ───────────────────────────────────
  'cash.pending.delivery': 'Livraison',
  'cash.pending.anomaly.named': 'Livrée par {name} · encaissement non déclaré',
  'cash.pending.anomaly.anon': 'Livrée · encaissement non déclaré',
  'cash.unrecorded.title.one': '{count} livraison sans encaissement enregistré',
  'cash.unrecorded.title.many':
      '{count} livraisons sans encaissement enregistré',
  'cash.unrecorded.body':
      'Montant annoncé : {amount} {currency}. La livraison est terminée, mais '
          'le transporteur n’a pas déclaré ce qu’il a encaissé — cela arrive '
          'quand la course est clôturée depuis l’administration et non depuis '
          'son application. Contactez-le pour régulariser.',

  // ── Encaissement déclaré par le commerçant, à confirmer ─────────────────
  'cash.to_confirm.title':
      'Le commerçant déclare que vous avez encaissé {amount}',
  'cash.to_confirm.expected': 'Montant annoncé sur la livraison : {amount}.',
  'cash.to_confirm.discrepancy': ' Écart déclaré : {reason}.',
  'cash.to_confirm.note':
      'Tant que vous n’avez pas confirmé, cette somme n’entre dans aucun compte.',

  // ── Choix du transporteur ───────────────────────────────────────────────
  'cash.picker.title': 'Qui a effectué cette livraison ?',
  'cash.picker.hint':
      'Cette livraison ne désigne aucun transporteur. Cherchez-le par son nom '
          'ou son téléphone.',
  'cash.picker.field': 'Nom ou téléphone',
  'cash.picker.failed': 'Recherche impossible',
  'cash.picker.too_many': 'Trop de correspondances — précisez le nom.',
  'cash.picker.none': 'Aucun transporteur trouvé.',
  'cash.picker.driver': 'Transporteur',
  'cash.picker.no_account':
      'Pas de compte dans l’application : il ne pourrait rien confirmer',

  // ── Le nom d'une contrepartie ───────────────────────────────────────────
  // Employé DANS les phrases ci-dessus (« Détenue par {who} »), donc il doit
  // suivre la langue, sans quoi une phrase arabe se terminerait par « ce
  // transporteur ».
  'cash.party.driver': 'ce transporteur',
  'cash.party.fleet': 'cette entreprise',
  'cash.party.merchant': 'ce commerçant',
  'cash.party.unknown': 'cette contrepartie',

  // ── Motifs d'écart à la porte ───────────────────────────────────────────
  'cash.discrepancy.somme_incomplete': 'Le client n’avait pas la totalité',
  'cash.discrepancy.refus_de_payer': 'Le client a refusé de payer',
  'cash.discrepancy.pas_de_monnaie': 'Pas de monnaie',
  'cash.discrepancy.montant_conteste': 'Le client a contesté le montant',
  'cash.discrepancy.autre': 'Autre',
};

const Map<String, String> _ar = {
  'cash.title.driver': 'صندوقي',
  'cash.title.fleet': 'صندوق الشركة',
  'cash.title.merchant': 'التحصيلات',

  'cash.section.collections_to_confirm': 'تحصيلات بانتظار التأكيد',
  'cash.section.to_confirm': 'بانتظار التأكيد',
  'cash.section.accounts': 'حساباتي',
  'cash.section.carriers': 'ناقلوني',
  'cash.section.pending': 'جارية — لم تُحصَّل بعد',
  'cash.section.collections': 'تفاصيل التحصيلات',
  'cash.section.awaiting_other': 'بانتظار الطرف الآخر',
  'cash.collections.preview': 'آخر {count} عملية تسليم محصَّلة من أصل {total}.',

  'cash.awaiting.driver': 'لم يؤكّد التاجر الاستلام بعد.',
  'cash.awaiting.fleet': 'لم يؤكّد الطرف الآخر بعد.',
  'cash.awaiting.merchant': 'لم يؤكّد الناقل بعد.',

  'cash.total.owed_by_drivers': 'ما يدين به سائقوك لك',
  'cash.total.collected_for_you': 'النقد المحصَّل لصالحك',
  'cash.total.owed_to_merchants': 'ما تدين به للتجار',
  'cash.total.you_hold': 'النقد الذي بحوزتك',
  'cash.total.position': 'الوضعية الإجمالية',
  'cash.total.note.both':
      'ما بحوزتك يُسلَّم إلى كل تاجر، وما بحوزة سائقيك يعود إليك عند مرورهم '
          'القادم. إيشانغو لا تحتفظ بهذا المال أبداً.',
  'cash.total.note.driver':
      'أجرتك مخصومة سلفاً. الباقي يُسلَّم إلى كل تاجر عند استلامك التالي من '
          'عنده. إيشانغو لا تحتفظ بهذا المال أبداً.',
  'cash.total.note.merchant':
      'بحوزة ناقليك، بعد خصم أجرتهم، إلى حين مرورهم القادم. إيشانغو لا تحتفظ '
          'بهذا المال أبداً.',
  'cash.expected.total': 'للتحصيل عند الأبواب: {amount} {currency}',
  'cash.expected.count.one': 'عملية تسليم واحدة جارية. لم يُقبض هذا المال بعد.',
  'cash.expected.count.many':
      '{count} عمليات تسليم جارية. لم يُقبض هذا المال بعد.',
  'cash.commission.total': 'عمولة إيشانغو التراكمية: {amount} {currency}',
  'cash.commission.note':
      'مخصومة سلفاً من رحلاتك. تُفوتر بشكل منفصل من إيشانغو، لا من هذا التطبيق.',

  'cash.empty.fleet.title': 'لا توجد حركات نقدية',
  'cash.empty.fleet.hint':
      'ما يحصّله سائقوك يظهر هنا، مع ما يتعيّن عليك تحويله إلى كل تاجر.',
  'cash.empty.driver.title': 'لا توجد بحوزتك أي مبالغ',
  'cash.empty.driver.hint':
      'التحصيلات التي تصرّح بها عند التسليم تظهر هنا، مع ما تدين به لكل تاجر.',
  'cash.empty.unrecorded.title': 'لا يوجد رصيد مفتوح',
  'cash.empty.unrecorded.hint':
      'لكن عمليات تسليم أُغلقت خارج التطبيق لم تترك أي تحصيل: سوِّها من التنبيه '
          'أعلاه.',
  'cash.empty.pending.title': 'لا شيء لاستردادِه حالياً',
  'cash.empty.pending.hint':
      'عمليات التسليم الجارية لم تُحصَّل بعد: يظهر المبلغ عند تسليم الطرد.',
  'cash.empty.none.title': 'لا توجد مبالغ منتظَرة',
  'cash.empty.none.hint':
      'سترى هنا ما يدين به كل ناقل لك، بمجرد تحصيل عملية تسليم عند الباب.',

  'cash.declare.title': 'تسجيل دفعة',
  'cash.declare.subtitle': 'مع {name}. لن يُخصم المبلغ إلا بعد تأكيد الطرف الآخر.',
  'cash.declare.failed': 'تعذّر التصريح',
  'cash.declare.done': 'تم التصريح بالتسليم. سيُخصم بعد التأكيد.',
  'cash.confirm.failed': 'تعذّر التأكيد',
  'cash.confirm.done': 'تم تأكيد التسليم — خُصم {amount}.',
  'cash.regularise.title': 'التصريح بالتحصيل',
  'cash.regularise.subtitle.named':
      'كم حصّل {name} على عملية التسليم هذه؟ عليه التأكيد قبل احتساب المبلغ.',
  'cash.regularise.subtitle.anon':
      'كم حُصِّل على عملية التسليم هذه؟ على الناقل التأكيد قبل احتساب المبلغ.',
  'cash.regularise.done': 'تم التصريح. بانتظار تأكيد الناقل.',
  'cash.collection.confirm.done': 'تم تأكيد التحصيل — دخل صندوقك.',
  'cash.collection.dispute.title': 'الاعتراض على هذا التحصيل؟',
  'cash.collection.dispute.body':
      'أنت تصرّح بأنك لم تحصّل {amount} {currency} على عملية التسليم هذه. لن '
          'يُحتسب شيء وسيُخطَر إيشانغو.',
  'cash.collection.dispute.done': 'تم الاعتراض على التحصيل.',
  'cash.dispute.failed': 'تعذّر الاعتراض',
  'cash.remittance.dispute.title': 'الاعتراض على هذا التسليم؟',
  'cash.remittance.dispute.body':
      'أنت تصرّح بأنك لم تستلم {amount}. يبقى المبلغ مستحقاً وسيُخطَر إيشانغو.',
  'cash.remittance.dispute.done': 'تم الاعتراض على التسليم. يبقى المبلغ مستحقاً.',
  'cash.discrepancy.why': 'لماذا يختلف هذا المبلغ؟',

  'cash.action.back': 'رجوع',
  'cash.action.dispute': 'اعتراض',
  'cash.action.confirm': 'تأكيد',
  'cash.action.cancel': 'إلغاء',
  'cash.action.validate': 'تأكيد المبلغ',
  'cash.action.call': 'اتصال',
  'cash.action.received_nothing': 'لم أستلم شيئاً',
  'cash.action.remitted': 'سلّمتُ',
  'cash.action.received': 'استلمتُ',

  'cash.sense.held_by': 'بحوزة {who}.',
  'cash.sense.you_owe': 'أنت مدين بهذا المبلغ لـ{who}.',
  'cash.sense.you_hold': 'هذا المبلغ بحوزتك لصالح {who}.',
  'cash.sense.owes_you': '{who} مدين لك بهذا المبلغ (رحلة لم يغطّها التحصيل).',
  'cash.sense.upstream_unknown': 'مبلغ محتَجز في الأعلى، بانتظار التسليم.',
  'cash.sense.reverse_unknown': 'مبلغ مستحق في الاتجاه المعاكس.',
  'cash.blocked.driver':
      'بلغتَ السقف: لا مزيد من الرحلات المحصَّلة لهذا التاجر قبل تسليمك.',
  'cash.blocked.other': 'بلغ السقف مع {who}.',
  'cash.account.unnamed': 'حساب {id}',

  'cash.declared_by.driver': 'يصرّح الناقل بأنه سلّمك هذا المبلغ.',
  'cash.declared_by.fleet': 'تصرّح شركة النقل بأنها سلّمتك هذا المبلغ.',
  'cash.declared_by.merchant': 'يصرّح التاجر بأنه سلّمك هذا المبلغ.',
  'cash.declared_by.unknown': 'يصرّح الطرف الآخر بأنه سلّمك هذا المبلغ.',

  'cash.amount.label': 'المبلغ ({currency})',
  'cash.amount.max': 'الحد الأقصى {amount}',

  'cash.line.collected': 'المقبوض من المستلِم',
  'cash.line.retained.driver': 'أجرتك المقتطعة',
  'cash.line.retained.other': 'اقتطعه الناقل',
  'cash.line.net.driver': 'الباقي للتسليم',
  'cash.line.net.fleet': 'للتسليم إلى التاجر',
  'cash.line.net.merchant': 'يعود إليك',
  'cash.discrepancy.line': '{reason} — كان المنتظَر {amount}.',
  'cash.discrepancy.default': 'فارق مُبلَّغ عنه',

  'cash.pending.delivery': 'عملية تسليم',
  'cash.pending.anomaly.named': 'سلّمها {name} · لم يُصرَّح بالتحصيل',
  'cash.pending.anomaly.anon': 'سُلّمت · لم يُصرَّح بالتحصيل',
  'cash.unrecorded.title.one': 'عملية تسليم واحدة بلا تحصيل مسجَّل',
  'cash.unrecorded.title.many': '{count} عمليات تسليم بلا تحصيل مسجَّل',
  'cash.unrecorded.body':
      'المبلغ المعلَن: {amount} {currency}. انتهت عملية التسليم، لكن الناقل لم '
          'يصرّح بما حصّله — يحدث هذا عندما تُغلق الرحلة من لوحة الإدارة لا من '
          'تطبيقه. اتصل به للتسوية.',

  'cash.to_confirm.title': 'يصرّح التاجر بأنك حصّلت {amount}',
  'cash.to_confirm.expected': 'المبلغ المعلَن على عملية التسليم: {amount}.',
  'cash.to_confirm.discrepancy': ' الفارق المصرَّح به: {reason}.',
  'cash.to_confirm.note': 'ما لم تؤكّد، لا يدخل هذا المبلغ في أي حساب.',

  'cash.picker.title': 'من قام بعملية التسليم هذه؟',
  'cash.picker.hint':
      'عملية التسليم هذه لا تحدّد أي ناقل. ابحث عنه بالاسم أو رقم الهاتف.',
  'cash.picker.field': 'الاسم أو رقم الهاتف',
  'cash.picker.failed': 'تعذّر البحث',
  'cash.picker.too_many': 'نتائج كثيرة جداً — حدّد الاسم أكثر.',
  'cash.picker.none': 'لم يُعثر على أي ناقل.',
  'cash.picker.driver': 'ناقل',
  'cash.picker.no_account': 'لا حساب له في التطبيق: لن يستطيع تأكيد أي شيء',

  'cash.party.driver': 'هذا الناقل',
  'cash.party.fleet': 'هذه الشركة',
  'cash.party.merchant': 'هذا التاجر',
  'cash.party.unknown': 'هذا الطرف',

  'cash.discrepancy.somme_incomplete': 'لم يكن لدى الزبون المبلغ كاملاً',
  'cash.discrepancy.refus_de_payer': 'رفض الزبون الدفع',
  'cash.discrepancy.pas_de_monnaie': 'لا يوجد صرف',
  'cash.discrepancy.montant_conteste': 'اعترض الزبون على المبلغ',
  'cash.discrepancy.autre': 'أخرى',
};
