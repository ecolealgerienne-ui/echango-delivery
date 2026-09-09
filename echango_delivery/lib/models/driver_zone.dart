/// La zone de travail d'un transporteur, telle que le serveur la sert.
///
/// ── Un point d'ancrage, un rayon — aucune géographie administrative ────────
///
/// La wilaya a été retirée (elle imposait une liste des 58 et couplait l'app à
/// un pays). La préférence tient en un point (`center`) et un rayon
/// (`radiusKm`). Les autres champs existent parce que l'écran ne peut pas les
/// deviner :
///
/// - [suggestedRadiusKm] est ce que l'écran **propose** à qui n'a jamais réglé.
///   Ce n'est pas [radiusKm] : seul ce dernier filtre.
/// - [anchorSet] dit si un point d'ancrage existe. **Sans lui, la liste des
///   opportunités est vide** — l'écran doit inviter à en poser un, pas laisser
///   croire à une panne.
/// - [position] est la position GPS vive, servie pour **pré-remplir** la carte
///   au premier réglage. Elle ne filtre rien.
library;

import 'package:latlong2/latlong.dart';

class DriverZone {
  /// Point d'ancrage choisi. `null` = aucune préférence de zone.
  final LatLng? center;

  /// Rayon choisi, en kilomètres. `null` = aucune limite de distance.
  final int? radiusKm;

  /// Ce que l'écran propose par défaut — jamais ce qu'il applique.
  final int suggestedRadiusKm;

  /// Un point d'ancrage est-il enregistré ? Faux ⇒ opportunités vides + CTA.
  final bool anchorSet;

  /// La position GPS du transporteur est-elle connue du serveur ?
  final bool positionKnown;

  /// La position GPS vive, pour pré-remplir la carte. Ne filtre pas.
  final LatLng? position;

  const DriverZone({
    this.center,
    this.radiusKm,
    required this.suggestedRadiusKm,
    required this.anchorSet,
    required this.positionKnown,
    this.position,
  });

  /// Rien n'est réglé : ce transporteur n'a pas de zone.
  bool get isUnset => center == null && radiusKm == null;

  factory DriverZone.fromJson(Map<String, dynamic> json) {
    int? asInt(dynamic v) {
      if (v is int) return v;
      if (v is num) return v.round();
      if (v is String) return int.tryParse(v.trim());
      return null;
    }

    double? asDouble(dynamic v) {
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v.trim());
      return null;
    }

    LatLng? asPoint(dynamic v) {
      if (v is! Map) return null;
      final lat = asDouble(v['latitude']);
      final lng = asDouble(v['longitude']);
      if (lat == null || lng == null) return null;
      if (lat == 0 && lng == 0) return null;
      return LatLng(lat, lng);
    }

    return DriverZone(
      center: asPoint(json['center']),
      radiusKm: asInt(json['radius_km']),
      // Un défaut de repli ici est sans danger : il ne sert qu'à pré-remplir un
      // champ, jamais à filtrer.
      suggestedRadiusKm: asInt(json['suggested_radius_km']) ?? 15,
      anchorSet: json['anchor_set'] == true,
      positionKnown: json['position_known'] == true,
      position: asPoint(json['position']),
    );
  }
}
