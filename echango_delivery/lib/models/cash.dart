import 'package:equatable/equatable.dart';

/// La chaîne de l'argent : `conducteur → entreprise → commerçant`.
///
/// Le conducteur encaisse à la porte, l'entreprise perçoit de son conducteur,
/// le commerçant est le destinataire final. Le rang situe chaque acteur ; il
/// décide, à lui seul, dans quel sens se lit une dette.
///
/// `null` sur un type inconnu — le serveur pourrait en ajouter un, et deviner
/// serait pire que se taire (l'appelant retombe alors sur un libellé neutre).
int? cashChainRank(String? party) => switch (party) {
      'driver' => 0,
      'fleet' => 1,
      'merchant' => 2,
      _ => null,
    };

/// Où se situe la contrepartie par rapport à celui qui regarde.
enum CashSide {
  /// Elle est en amont : c'est elle qui encaisse. Une dette positive veut dire
  /// qu'elle **détient** de l'argent qui me revient.
  upstream,

  /// Elle est en aval : c'est moi qui encaisse pour elle. Une dette positive
  /// veut dire que **je détiens** de l'argent qui lui revient.
  downstream,

  /// Type de contrepartie non renseigné ou inconnu. L'écran doit alors rester
  /// neutre plutôt que d'affirmer un sens.
  unknown,
}

/// De quel côté de la chaîne se trouve [counterpartyType] pour [viewer].
CashSide cashSide(String viewer, String? counterpartyType) {
  final me = cashChainRank(viewer);
  final other = cashChainRank(counterpartyType);
  if (me == null || other == null || me == other) return CashSide.unknown;
  return other < me ? CashSide.upstream : CashSide.downstream;
}

/// Comment nommer la contrepartie dans une phrase.
///
/// Une entreprise voit à la fois des conducteurs et des commerçants dans la
/// même liste : les appeler tous « ce transporteur », comme le faisait l'écran,
/// est faux pour la moitié d'entre eux.
String cashPartyLabel(String? type) => switch (type) {
      'driver' => 'ce transporteur',
      'fleet' => 'cette entreprise',
      'merchant' => 'ce commerçant',
      _ => 'cette contrepartie',
    };

/// Dette d'un transporteur envers un commerçant, ou l'inverse selon le profil
/// qui regarde.
///
/// ── Pourquoi une dette par contrepartie, et non un solde global ─────────────
///
/// Le transporteur ne doit rien « à la plateforme » : Echango ne touche jamais
/// l'argent. Il doit une somme à *chaque commerçant* dont il a encaissé une
/// livraison, et c'est ainsi que ça se règle — un commerçant à la fois, au
/// prochain enlèvement. Un total unique n'aurait aucun destinataire.
class CashBalance extends Equatable {
  /// Identifiant de la contrepartie : le commerçant vu du transporteur, le
  /// transporteur vu du commerçant.
  final String counterpartyId;

  /// `driver`, `fleet` ou `merchant` — null si le serveur ne le renseigne pas.
  final String? counterpartyType;
  final String? name;
  final String? phone;
  final double debt;

  /// Vrai quand la dette atteint le plafond : plus aucune course encaissée ne
  /// sera confiée à ce transporteur pour ce commerçant tant qu'il n'a pas remis.
  final bool blocked;

  /// La position est **signée**, et son signe a un sens absolu : positif quand
  /// la partie **en amont** de la chaîne détient l'argent de celle en aval.
  ///
  /// ⚠️ **`driverOwes`/`merchantOwes` ont été retirés, parce que leurs noms
  /// mentaient dès qu'une entreprise de transport regardait.** L'entreprise est
  /// au MILIEU de la chaîne : ses conducteurs lui doivent, elle doit aux
  /// commerçants. Un même `debt > 0` désignait donc, sur le même écran, tantôt
  /// « mon conducteur détient » et tantôt « je détiens et je dois » — et
  /// l'écran, qui traitait toute non-conducteur comme un commerçant, décrivait
  /// **la moitié des soldes d'une entreprise à l'envers**.
  ///
  /// Le sens ne se déduit pas du profil qui regarde, mais de la POSITION de la
  /// contrepartie par rapport à lui : voir [cashSide].
  bool get upstreamHolds => debt > 0;

  /// Somme due, quel que soit le sens.
  double get outstanding => debt.abs();

  const CashBalance({
    required this.counterpartyId,
    required this.debt,
    this.counterpartyType,
    this.name,
    this.phone,
    this.blocked = false,
  });

  /// Vu du transporteur : la contrepartie est son facilitateur, ou le
  /// commerçant quand la course n'en porte pas.
  ///
  /// ⚠️ `counterparty_*` d'abord, `merchant_*` en repli. Le serveur ne
  /// renseigne les seconds que lorsque la contrepartie est effectivement un
  /// commerçant — ils valent `null` face à une entreprise, et les lire seuls
  /// affichait « Compte  » sans identifiant ni nom. Le repli reste pour les
  /// réponses d'un serveur antérieur à la généralisation.
  factory CashBalance.fromDriverJson(Map<String, dynamic> json) => CashBalance(
        counterpartyId:
            (json['counterparty_id'] ?? json['merchant_id'] ?? '') as String,
        counterpartyType: json['counterparty_type'] as String?,
        name: (json['counterparty_name'] ?? json['merchant_name']) as String?,
        phone: (json['counterparty_phone'] ?? json['merchant_phone']) as String?,
        debt: (json['debt'] as num?)?.toDouble() ?? 0,
        blocked: json['blocked'] == true,
      );

  /// Vu du commerçant : la contrepartie est le facilitateur de la course, ou
  /// le transporteur lui-même quand elle n'en porte pas.
  factory CashBalance.fromMerchantJson(Map<String, dynamic> json) => CashBalance(
        counterpartyId:
            (json['counterparty_id'] ?? json['driver_id'] ?? '') as String,
        counterpartyType: json['counterparty_type'] as String?,
        name: (json['counterparty_name'] ?? json['driver_name']) as String?,
        phone: (json['counterparty_phone'] ?? json['driver_phone']) as String?,
        debt: (json['debt'] as num?)?.toDouble() ?? 0,
      );

  String get displayName =>
      (name != null && name!.isNotEmpty) ? name! : 'Compte $counterpartyId';

  @override
  List<Object?> get props => [counterpartyId, counterpartyType, debt, blocked];
}

/// Ensemble des dettes d'un compte, avec la devise et le plafond.
class CashLedger {
  final List<CashBalance> balances;
  final String currency;

  /// Plafond de dette. `null` côté commerçant : il ne le subit pas, il en
  /// bénéficie — c'est ce qui borne ce qu'un transporteur peut détenir de lui.
  final double? ceiling;

  /// Commission cumulée due à Echango. Côté transporteur uniquement.
  ///
  /// ⚠️ Son recouvrement n'est pas construit : c'est un montant enregistré, pas
  /// une somme que l'application sait encaisser. Affiché pour que le
  /// transporteur ne découvre pas une facture, pas comme une dette exigible ici.
  final double? platformCommission;

  const CashLedger({
    required this.balances,
    required this.currency,
    this.ceiling,
    this.platformCommission,
  });

  /// Somme des positions, signée. Un repère, jamais un montant à régler d'un
  /// coup : il est dû à — ou par — plusieurs personnes différentes.
  ///
  /// ⚠️ **N'a de sens que pour un acteur situé à un bout de la chaîne.** Le
  /// conducteur ne fait face qu'à des parties en aval, le commerçant qu'à des
  /// parties en amont : leur total va donc dans un seul sens. L'entreprise de
  /// transport, elle, est au milieu — ses conducteurs lui doivent et elle doit
  /// aux commerçants —, et ce total **soustrait sa créance de sa dette** pour
  /// n'en donner qu'un nombre qui ne désigne rien. Voir [totalOn].
  double get total =>
      balances.fold<double>(0, (sum, b) => sum + b.debt);

  /// Somme signée des positions dont la contrepartie est du côté [side] pour
  /// [viewer]. `null` si aucune contrepartie ne s'y trouve.
  ///
  /// Le `null` compte : il permet à l'écran de n'afficher une ligne que
  /// lorsqu'elle existe, sans avoir à savoir quel profil regarde. Un `0` aurait
  /// affiché « vous devez 0 » à un conducteur qui ne doit à personne.
  double? totalOn(CashSide side, String viewer) {
    final rows =
        balances.where((b) => cashSide(viewer, b.counterpartyType) == side);
    if (rows.isEmpty) return null;
    return rows.fold<double>(0, (sum, b) => sum + b.debt);
  }

  bool get isEmpty => balances.isEmpty;
}

/// Remise d'espèces entre un transporteur et un commerçant.
///
/// Tant que [confirmedAt] est nul, la remise **ne réduit pas la dette** : une
/// déclaration unilatérale est une affirmation, pas une preuve, et c'est
/// précisément ici que le registre doit être incontestable — une confirmation
/// éteint une dette.
class CashRemittance extends Equatable {
  final String id;
  final double amount;
  final String currency;

  /// `driver`, `fleet` ou `merchant` — le serveur y écrit un `PartyType`
  /// complet depuis le chantier facilitateur. Détermine qui doit confirmer :
  /// l'autre, toujours.
  ///
  /// ⚠️ Ce commentaire disait « `driver` ou `merchant` », et l'écran s'y fiait
  /// pour nommer le déclarant à partir du profil qui regarde. Une entreprise de
  /// transport déclare pourtant des remises, dans les deux sens.
  final String declaredBy;
  final DateTime declaredAt;
  final DateTime? confirmedAt;
  final DateTime? disputedAt;
  final String? disputeReason;

  final String driverId;
  final String merchantId;

  const CashRemittance({
    required this.id,
    required this.amount,
    required this.currency,
    required this.declaredBy,
    required this.declaredAt,
    required this.driverId,
    required this.merchantId,
    this.confirmedAt,
    this.disputedAt,
    this.disputeReason,
  });

  factory CashRemittance.fromJson(Map<String, dynamic> json) => CashRemittance(
        id: (json['id'] ?? '') as String,
        amount: (json['amount'] as num?)?.toDouble() ?? 0,
        currency: (json['currency'] ?? '') as String,
        declaredBy: (json['declared_by'] ?? '') as String,
        declaredAt: DateTime.tryParse((json['declared_at'] ?? '') as String) ??
            DateTime.now(),
        confirmedAt: json['confirmed_at'] is String
            ? DateTime.tryParse(json['confirmed_at'] as String)
            : null,
        disputedAt: json['disputed_at'] is String
            ? DateTime.tryParse(json['disputed_at'] as String)
            : null,
        disputeReason: json['dispute_reason'] as String?,
        driverId: (json['driver_id'] ?? '') as String,
        merchantId: (json['merchant_id'] ?? '') as String,
      );

  bool get isConfirmed => confirmedAt != null;
  bool get isDisputed => disputedAt != null;
  bool get isPending => !isConfirmed && !isDisputed;

  /// Cette remise attend-elle une action de [persona] ?
  ///
  /// Une remise n'est jamais confirmable par son propre déclarant : le serveur
  /// le refuse, et l'afficher comme actionnable promettrait un bouton qui
  /// échouerait.
  bool awaitsActionFrom(String persona) => isPending && declaredBy != persona;

  String get formattedAmount => '${amount.toStringAsFixed(0)} $currency'.trim();

  @override
  List<Object?> get props => [id, confirmedAt, disputedAt];
}

/// Encaissement enregistré à une livraison.
class CashCollectionEntry extends Equatable {
  final String id;
  final double expectedAmount;
  final double collectedAmount;
  final String currency;

  /// Renseigné uniquement quand les deux montants diffèrent — un motif sur une
  /// ligne conforme laisserait croire à un incident.
  final String? discrepancyReason;
  final String? notes;
  final DateTime collectedAt;

  /// Ce que le transporteur a prélevé sur ces espèces.
  ///
  /// Sa rémunération **réellement retenue**, plafonnée à ce qu'il a perçu — et
  /// non le montant théorique de la course, qui différerait sur une livraison
  /// payée en partie.
  final double retainedAmount;

  /// Ce qui revient au commerçant sur cette livraison.
  ///
  /// Calculé par le serveur sur le montant **perçu**, jamais sur celui qui
  /// était attendu : sur un écart à la porte, annoncer la somme demandée
  /// promettrait de l'argent qui ne viendra pas.
  final double netAmount;

  /// Identifiant Fleetbase de la livraison, pour retrouver la fiche.
  final String orderUuid;

  /// `driver` ou `merchant`. Une ligne déclarée par le commerçant régularise
  /// une livraison close hors application : elle ne compte dans aucune dette
  /// tant que le transporteur ne l'a pas confirmée.
  final String declaredBy;
  final DateTime? confirmedAt;
  final DateTime? disputedAt;
  final String? disputeReason;

  /// Attend une confirmation du transporteur — et n'est donc, pour l'instant,
  /// qu'une affirmation du commerçant.
  bool get awaitsDriverConfirmation =>
      declaredBy == 'merchant' && confirmedAt == null && disputedAt == null;

  bool get isDisputed => disputedAt != null;

  const CashCollectionEntry({
    required this.id,
    required this.expectedAmount,
    required this.collectedAmount,
    required this.currency,
    required this.collectedAt,
    this.retainedAmount = 0,
    this.netAmount = 0,
    this.orderUuid = '',
    this.declaredBy = 'driver',
    this.confirmedAt,
    this.disputedAt,
    this.disputeReason,
    this.discrepancyReason,
    this.notes,
  });

  factory CashCollectionEntry.fromJson(Map<String, dynamic> json) =>
      CashCollectionEntry(
        id: (json['id'] ?? '') as String,
        expectedAmount: (json['expected_amount'] as num?)?.toDouble() ?? 0,
        collectedAmount: (json['collected_amount'] as num?)?.toDouble() ?? 0,
        currency: (json['currency'] ?? '') as String,
        discrepancyReason: json['discrepancy_reason'] as String?,
        notes: json['notes'] as String?,
        retainedAmount: (json['retained_amount'] as num?)?.toDouble() ?? 0,
        // Repli sur la soustraction pour les lignes servies avant que le
        // serveur ne calcule le net : mieux vaut un chiffre juste calculé ici
        // qu'un zéro affiché comme un fait.
        netAmount: (json['net_amount'] as num?)?.toDouble() ??
            ((json['collected_amount'] as num?)?.toDouble() ?? 0) -
                ((json['retained_amount'] as num?)?.toDouble() ?? 0),
        orderUuid: (json['order_uuid'] ?? '') as String,
        // Défaut `driver` : une ligne servie par un BFF antérieur à la
        // régularisation n'a pas ce champ, et elle EST une déclaration du
        // transporteur. Le défaut inverse l'aurait affichée « en attente ».
        declaredBy: (json['declared_by'] ?? 'driver') as String,
        confirmedAt: json['confirmed_at'] is String
            ? DateTime.tryParse(json['confirmed_at'] as String)
            : null,
        disputedAt: json['disputed_at'] is String
            ? DateTime.tryParse(json['disputed_at'] as String)
            : null,
        disputeReason: json['dispute_reason'] as String?,
        collectedAt:
            DateTime.tryParse((json['collected_at'] ?? '') as String) ?? DateTime.now(),
      );

  bool get hasDiscrepancy => collectedAmount != expectedAmount;

  @override
  List<Object?> get props => [id];
}

/// Libellés des motifs d'écart, du point de vue de qui les lit.
///
/// Les codes du serveur sont faits pour être comptés, pas affichés.
const cashDiscrepancyLabels = <String, String>{
  'somme_incomplete': 'Le client n\'avait pas la totalité',
  'refus_de_payer': 'Le client a refusé de payer',
  'pas_de_monnaie': 'Pas de monnaie',
  'montant_conteste': 'Le client a contesté le montant',
  'autre': 'Autre',
};

/// Une livraison dont l'argent sera réclamé à une porte, et n'est encore dans
/// la poche de personne.
///
/// ── Pourquoi ce n'est PAS une entrée du registre ────────────────────────────
///
/// Le registre enregistre des faits : quelqu'un a perçu telle somme. Une somme
/// attendue n'est un fait pour personne — le transporteur ne la tient pas
/// encore, et la livraison peut échouer. L'inscrire au registre créerait une
/// dette sur une hypothèse.
///
/// Mais l'omettre de l'écran était pire : un commerçant dont trois courses
/// étaient en route lisait « 0 DZD, aucune somme en attente ». Un écran vide
/// qui rassure à tort vaut moins qu'un écran qui distingue « perçu » de
/// « attendu ».
class PendingCollection extends Equatable {
  final String orderUuid;
  final String? bffOrderId;
  final double expectedAmount;

  /// Statut Fleetbase — il dit à quelle distance de la porte on est.
  final String? status;
  final String? driverName;
  final String? driverPhone;
  final String? dropoffName;

  const PendingCollection({
    required this.orderUuid,
    required this.expectedAmount,
    this.bffOrderId,
    this.status,
    this.driverName,
    this.driverPhone,
    this.dropoffName,
  });

  factory PendingCollection.fromJson(Map<String, dynamic> json) => PendingCollection(
        orderUuid: (json['uuid'] ?? '') as String,
        bffOrderId: json['bff_order_id'] as String?,
        expectedAmount: (json['expected_amount'] as num?)?.toDouble() ?? 0,
        status: json['status'] as String?,
        driverName: json['driver_name'] as String?,
        driverPhone: json['driver_phone'] as String?,
        dropoffName: json['dropoff_name'] as String?,
      );

  /// Vrai quand un transporteur tient déjà le colis : l'argent est bien plus
  /// proche d'arriver que sur une course encore en recherche.
  bool get isUnderway => driverName != null;

  @override
  List<Object?> get props => [orderUuid, expectedAmount, status];
}

/// Ce que le registre ne sait pas encore, en deux catégories très différentes.
///
/// Les mélanger serait une faute : [inFlight] est normal — l'argent est en
/// route, il arrivera. [unrecorded] est une **anomalie** — la livraison est
/// faite, l'argent a changé de mains ou non, et rien ne l'enregistre. La
/// première se regarde, la seconde se règle.
class PendingCollections {
  final String currency;
  final List<PendingCollection> inFlight;

  /// Livraisons terminées dont aucun encaissement n'a été déclaré.
  ///
  /// ── D'où vient ce cas ───────────────────────────────────────────────────
  ///
  /// Le registre n'a qu'un chemin d'écriture : la clôture par l'application du
  /// transporteur. Une commande passée à « livrée » depuis la console Fleetbase
  /// — ce que fait un admin, légitimement — n'y laisse rien.
  ///
  /// Le montant affiché est celui qui était **annoncé**, jamais un montant
  /// perçu : personne ne nous a dit ce qui a réellement été remis. L'écrire au
  /// registre inventerait une dette ; le taire laisserait le commerçant devant
  /// un zéro.
  final List<PendingCollection> unrecorded;

  const PendingCollections({
    this.currency = '',
    this.inFlight = const [],
    this.unrecorded = const [],
  });

  factory PendingCollections.fromJson(Map<String, dynamic> json) {
    List<PendingCollection> listOf(String key) =>
        ((json[key] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(PendingCollection.fromJson)
            .toList();

    return PendingCollections(
      currency: (json['currency'] ?? '') as String,
      inFlight: listOf('orders'),
      unrecorded: listOf('unrecorded'),
    );
  }

  /// Recalculés localement plutôt que lus : le serveur les envoie, mais les
  /// dériver de la liste affichée garantit que le total et les lignes ne
  /// peuvent pas se contredire à l'écran.
  double get expectedTotal =>
      inFlight.fold<double>(0, (sum, p) => sum + p.expectedAmount);

  double get unrecordedTotal =>
      unrecorded.fold<double>(0, (sum, p) => sum + p.expectedAmount);

  bool get isEmpty => inFlight.isEmpty && unrecorded.isEmpty;
}
