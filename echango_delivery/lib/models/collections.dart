import 'package:equatable/equatable.dart';

/// Ce que les commandes d'un commerçant disent de l'argent.
///
/// ── Un fait, jamais un solde ────────────────────────────────────────────────
///
/// Ce modèle a remplacé le registre de caisse le 03/08/2026
/// (`docs/registre_caisse_precis.md`). Il ne porte **aucune dette, aucune
/// remise, aucune contrepartie** : la plateforme dit ce qui a été déclaré à
/// chaque porte, elle ne tient plus le compte de qui doit quoi à qui. Tenir
/// des soldes est de la trésorerie, pas de la logistique.
///
/// Les trois listes ne sont pas trois filtres d'une même chose : elles
/// répondent à trois questions différentes, et la troisième est la seule qui
/// appelle une action.
class MerchantCollections extends Equatable {
  const MerchantCollections({
    required this.currency,
    required this.expectedTotal,
    required this.expected,
    required this.collectedTotal,
    required this.collected,
    required this.unrecordedTotal,
    required this.unrecorded,
  });

  /// ⚠️ Peut être `null` : voir `CollectionLine.expectedAmount`.
  final String? currency;

  /// **En route.** Un montant est annoncé, la livraison n'est pas finie.
  /// Personne ne tient encore cet argent.
  final double expectedTotal;
  final List<CollectionLine> expected;

  /// **Perçu.** Le transporteur a déclaré à la porte ce qu'il a pris.
  final double collectedTotal;
  final List<CollectionLine> collected;

  /// **Muet.** Livrée, un montant était annoncé, et rien n'a été déclaré — le
  /// cas normal étant une clôture faite depuis la console Fleetbase.
  ///
  /// ⚠️ Le montant affiché est celui qui était **annoncé**, jamais un montant
  /// perçu : nous ignorons ce qui a changé de mains, et le présenter comme
  /// perçu inventerait un fait (règle 10).
  final double unrecordedTotal;
  final List<CollectionLine> unrecorded;

  bool get isEmpty =>
      expected.isEmpty && collected.isEmpty && unrecorded.isEmpty;

  factory MerchantCollections.fromJson(Map<String, dynamic> json) =>
      MerchantCollections(
        currency: json['currency'] as String?,
        expectedTotal: (json['expected_total'] as num?)?.toDouble() ?? 0,
        expected: _lines(json['orders']),
        collectedTotal: (json['collected_total'] as num?)?.toDouble() ?? 0,
        collected: _lines(json['collected']),
        unrecordedTotal: (json['unrecorded_total'] as num?)?.toDouble() ?? 0,
        unrecorded: _lines(json['unrecorded']),
      );

  static List<CollectionLine> _lines(dynamic raw) => raw is List
      ? raw
          .whereType<Map<String, dynamic>>()
          .map(CollectionLine.fromJson)
          .toList()
      : const [];

  @override
  List<Object?> get props =>
      [currency, expectedTotal, expected, collectedTotal, collected, unrecordedTotal, unrecorded];
}

/// Une livraison, vue sous l'angle de l'argent.
class CollectionLine extends Equatable {
  const CollectionLine({
    required this.uuid,
    this.orderId,
    this.status,
    this.driverName,
    this.driverPhone,
    this.dropoffName,
    this.expectedAmount,
    this.collectedAmount,
    this.collectedAt,
    this.collectionReason,
    this.completedAt,
  });

  final String uuid;
  final String? orderId;
  final String? status;
  final String? driverName;
  final String? driverPhone;
  final String? dropoffName;

  /// ⚠️ **`null` et non zéro quand le montant manque.** « À encaisser : 0 » se
  /// lit comme une livraison gratuite ; l'absence, elle, se dit « — ». C'est la
  /// règle 10, et elle a déjà coûté deux fois sur ce sujet.
  final double? expectedAmount;

  /// Ce qui a réellement été perçu, `null` tant que rien n'est déclaré.
  ///
  /// ⚠️ **Zéro est une valeur, pas une absence** : un destinataire qui refuse
  /// de payer. Le distinguer de `null` est tout l'intérêt de cette liste — les
  /// confondre effacerait le seul cas où le commerçant doit être prévenu.
  final double? collectedAmount;
  final DateTime? collectedAt;

  /// Code d'une liste fermée, traduit par l'application. Le serveur ne renvoie
  /// jamais de motif rédigé : il serait en français pour un arabophone.
  final String? collectionReason;

  final DateTime? completedAt;

  bool get hasDiscrepancy =>
      collectedAmount != null &&
      expectedAmount != null &&
      collectedAmount != expectedAmount;

  factory CollectionLine.fromJson(Map<String, dynamic> json) => CollectionLine(
        uuid: json['uuid'] as String? ?? '',
        orderId: json['bff_order_id'] as String?,
        status: json['status'] as String?,
        driverName: json['driver_name'] as String?,
        driverPhone: json['driver_phone'] as String?,
        dropoffName: json['dropoff_name'] as String?,
        expectedAmount: (json['expected_amount'] as num?)?.toDouble(),
        collectedAmount: (json['collected_amount'] as num?)?.toDouble(),
        collectedAt: _date(json['collected_at']),
        collectionReason: json['collection_reason'] as String?,
        completedAt: _date(json['completed_at']),
      );

  static DateTime? _date(dynamic raw) =>
      raw is String ? DateTime.tryParse(raw) : null;

  @override
  List<Object?> get props => [
        uuid,
        orderId,
        status,
        driverName,
        driverPhone,
        dropoffName,
        expectedAmount,
        collectedAmount,
        collectedAt,
        collectionReason,
        completedAt,
      ];
}
