/// La zone de travail d'un transporteur, telle que le serveur la sert.
///
/// ── Ce que ce modèle porte, et pourquoi quatre champs et non deux ──────────
///
/// La préférence tient en deux valeurs — une wilaya, un rayon. Les deux autres
/// existent parce que l'écran ne peut pas les deviner :
///
/// - [suggestedRadiusKm] est ce que l'écran **propose** à quelqu'un qui n'a
///   jamais réglé sa zone. ⚠️ Ce n'est **pas** [radiusKm], et les confondre
///   ferait disparaître des courses pour tous ceux qui n'ont rien choisi. Seul
///   [radiusKm] filtre quoi que ce soit ; celui-ci ne fait que pré-remplir.
/// - [positionKnown] dit si le rayon peut s'appliquer. Sans position, il ne
///   filtre rien — l'écran doit pouvoir l'expliquer plutôt que de laisser
///   croire à un réglage qui agit.
library;

class DriverZone {
  /// Wilaya choisie. `null` = toutes les wilayas.
  final String? wilaya;

  /// Rayon choisi, en kilomètres. `null` = aucune limite de distance.
  final int? radiusKm;

  /// Ce que l'écran propose par défaut — jamais ce qu'il applique.
  final int suggestedRadiusKm;

  /// La position du transporteur est-elle connue du serveur ?
  final bool positionKnown;

  const DriverZone({
    this.wilaya,
    this.radiusKm,
    required this.suggestedRadiusKm,
    required this.positionKnown,
  });

  /// Le rayon n'a d'effet que s'il est choisi **et** qu'on sait où il est.
  bool get radiusApplies => radiusKm != null && positionKnown;

  /// Rien n'est réglé : ce transporteur voit toutes les courses.
  bool get isUnset => wilaya == null && radiusKm == null;

  factory DriverZone.fromJson(Map<String, dynamic> json) {
    int? asInt(dynamic v) {
      if (v is int) return v;
      if (v is num) return v.round();
      if (v is String) return int.tryParse(v.trim());
      return null;
    }

    final wilaya = json['wilaya'];
    return DriverZone(
      // ⚠️ Une chaîne vide vaut absence, pas « wilaya sans nom » — sinon
      // l'écran afficherait un filtre actif sur rien.
      wilaya: wilaya is String && wilaya.trim().isNotEmpty ? wilaya.trim() : null,
      radiusKm: asInt(json['radius_km']),
      // Un défaut de repli ici est sans danger : il ne sert qu'à pré-remplir un
      // champ, jamais à filtrer.
      suggestedRadiusKm: asInt(json['suggested_radius_km']) ?? 15,
      positionKnown: json['position_known'] == true,
    );
  }
}
