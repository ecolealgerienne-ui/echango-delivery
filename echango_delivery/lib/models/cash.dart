import 'package:equatable/equatable.dart';

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
  final String? name;
  final String? phone;
  final double debt;

  /// Vrai quand la dette atteint le plafond : plus aucune course encaissée ne
  /// sera confiée à ce transporteur pour ce commerçant tant qu'il n'a pas remis.
  final bool blocked;

  /// La position est **signée**. Positive : le transporteur détient des espèces
  /// du commerçant. Négative : le commerçant lui doit une rémunération que
  /// l'encaissement n'a pas couverte — course sans encaissement, ou client qui
  /// n'a payé qu'une partie. Les deux appellent une action, en sens inverse.
  bool get driverOwes => debt > 0;
  bool get merchantOwes => debt < 0;

  /// Somme due, quel que soit le sens.
  double get outstanding => debt.abs();

  const CashBalance({
    required this.counterpartyId,
    required this.debt,
    this.name,
    this.phone,
    this.blocked = false,
  });

  /// Vu du transporteur : la contrepartie est un commerçant.
  factory CashBalance.fromDriverJson(Map<String, dynamic> json) => CashBalance(
        counterpartyId: (json['merchant_id'] ?? '') as String,
        name: json['merchant_name'] as String?,
        phone: json['merchant_phone'] as String?,
        debt: (json['debt'] as num?)?.toDouble() ?? 0,
        blocked: json['blocked'] == true,
      );

  /// Vu du commerçant : la contrepartie est un transporteur.
  factory CashBalance.fromMerchantJson(Map<String, dynamic> json) => CashBalance(
        counterpartyId: (json['driver_id'] ?? '') as String,
        name: json['driver_name'] as String?,
        phone: json['driver_phone'] as String?,
        debt: (json['debt'] as num?)?.toDouble() ?? 0,
      );

  String get displayName =>
      (name != null && name!.isNotEmpty) ? name! : 'Compte $counterpartyId';

  @override
  List<Object?> get props => [counterpartyId, debt, blocked];
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
  double get total =>
      balances.fold<double>(0, (sum, b) => sum + b.debt);

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

  /// `driver` ou `merchant`. Détermine qui doit confirmer : l'autre, toujours.
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

  const CashCollectionEntry({
    required this.id,
    required this.expectedAmount,
    required this.collectedAmount,
    required this.currency,
    required this.collectedAt,
    this.retainedAmount = 0,
    this.netAmount = 0,
    this.orderUuid = '',
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
  final String? dropoffName;

  const PendingCollection({
    required this.orderUuid,
    required this.expectedAmount,
    this.bffOrderId,
    this.status,
    this.driverName,
    this.dropoffName,
  });

  factory PendingCollection.fromJson(Map<String, dynamic> json) => PendingCollection(
        orderUuid: (json['uuid'] ?? '') as String,
        bffOrderId: json['bff_order_id'] as String?,
        expectedAmount: (json['expected_amount'] as num?)?.toDouble() ?? 0,
        status: json['status'] as String?,
        driverName: json['driver_name'] as String?,
        dropoffName: json['dropoff_name'] as String?,
      );

  /// Vrai quand un transporteur tient déjà le colis : l'argent est bien plus
  /// proche d'arriver que sur une course encore en recherche.
  bool get isUnderway => driverName != null;

  @override
  List<Object?> get props => [orderUuid, expectedAmount, status];
}
