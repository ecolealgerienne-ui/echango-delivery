import 'merchant_order.dart' show DriverPosition;

/// Un conducteur et sa dernière position connue, tel que `GET
/// /flotte/drivers/positions` les sert.
///
/// ── Pourquoi `DriverPosition` est réemployée telle quelle ─────────────────
///
/// Parce que « depuis quand ce point date-t-il, et faut-il encore y croire »
/// est **la même question** des deux côtés : le commerçant la pose sur le
/// transporteur de sa livraison, l'entreprise sur chacun de ses conducteurs.
/// `isStale` et `freshness` portent cette réponse, et en écrire une seconde
/// version ferait deux seuils de fraîcheur pour un même relevé (règle 5).
///
/// ⚠️ Elle vit dans `merchant_order.dart` pour des raisons historiques — c'est
/// le commerçant qui en a eu besoin le premier. L'y laisser est un choix de
/// périmètre : la déplacer toucherait une dizaine d'imports pour ne rien
/// corriger. Le dire évite de croire que la classe est propre au commerçant.
class FleetDriverPosition {
  const FleetDriverPosition({
    required this.driverUuid,
    required this.position,
    this.name,
  });

  final String driverUuid;

  /// Le nom vient de Fleetbase, où l'opérateur l'a saisi — et non des champs
  /// facultatifs que le transporteur remplit à l'inscription, souvent vides.
  /// Il peut malgré tout manquer, d'où le type nullable et l'absence de repli
  /// inventé : un conducteur sans nom s'affiche par son absence de nom, pas
  /// sous celui d'un autre.
  final String? name;

  final DriverPosition position;

  /// Rend `null` — plutôt que de lever — quand l'enregistrement n'est pas
  /// exploitable.
  ///
  /// ⚠️ Le serveur n'envoie **que** les conducteurs qui ont une position
  /// (`readDriverPosition()` filtre les autres, `[0,0]` compris, qui est une
  /// absence et non un point au large du golfe de Guinée). Ce contrôle-ci est
  /// donc une seconde barrière : un seul enregistrement mal formé ne doit pas
  /// faire disparaître toute la flotte de la carte.
  static FleetDriverPosition? tryFromJson(Map<String, dynamic> json) {
    final uuid = json['driver_uuid'];
    final lat = json['latitude'];
    final lon = json['longitude'];
    if (uuid is! String || uuid.isEmpty) return null;
    if (lat is! num || lon is! num) return null;

    return FleetDriverPosition(
      driverUuid: uuid,
      name: json['name'] as String?,
      position: DriverPosition.fromJson(json),
    );
  }
}
