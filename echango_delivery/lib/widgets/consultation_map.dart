import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../theme/app_spacing.dart';

/// Une carte qu'on **regarde**, par opposition à une carte où l'on choisit.
///
/// ── Ce qu'elle tient, et pourquoi ça ne peut pas être recopié ─────────────
///
/// Deux choses seulement, et ce sont exactement celles qui doivent rester
/// identiques partout (règle 5, critère « si l'une change, l'autre doit-elle
/// changer ? » — oui pour les deux) :
///
/// 1. **La source des tuiles et son `userAgentPackageName`.** Ce n'est pas un
///    détail d'affichage : la politique d'usage d'OpenStreetMap exige un agent
///    identifiable, et une carte qui l'oublie est une carte qui peut se voir
///    couper le service. Recopiée à la main, la valeur diverge le jour où l'on
///    renomme le paquet — et l'écran qui l'a gardée continue d'afficher des
///    tuiles jusqu'à ce qu'il cesse d'en recevoir, sans erreur intermédiaire.
/// 2. **Ni rotation ni sélection.** Sur une carte qu'on ne fait que consulter,
///    une rotation accidentelle à deux doigts désoriente sans rien apporter, et
///    rien ne la remet droite puisqu'il n'y a pas de bouton pour ça.
///
/// Les repères, eux, restent à l'appelant : un transporteur et son point de
/// livraison chez le commerçant, toute une flotte chez l'entreprise. Ce sont
/// deux questions différentes, pas deux variantes d'une même.
///
/// ── Cadrage : `center`/`zoom`, OU `fitPoints` ────────────────────────────
///
/// Un `center` + `zoom` fixe convient quand l'appelant sait où regarder (la
/// position d'un transporteur). Il ne convient PAS pour « montre-moi tout » :
/// deux repères éloignés — une course à Alger, une à Tamanrasset — sortent du
/// cadre et l'écran paraît vide. `fitPoints` cadre alors TOUS les points au
/// premier rendu via `CameraFit.coordinates`, **vérifié présent dans
/// `flutter_map` 7.0.2** (`src/map/camera/camera_fit.dart`) — l'ancien
/// commentaire le disait « non vérifiable », il l'était.
class AppConsultationMap extends StatelessWidget {
  const AppConsultationMap({
    super.key,
    required this.markers,
    this.center,
    this.zoom = 14,
    this.fitPoints,
  }) : assert(center != null || fitPoints != null,
            'AppConsultationMap : fournir center OU fitPoints');

  final List<Marker> markers;

  /// Point de départ quand l'appelant choisit lui-même le cadrage. Ignoré si
  /// [fitPoints] est fourni et non vide.
  final LatLng? center;
  final double zoom;

  /// Les points à faire tenir tous ensemble dans la vue initiale. Prioritaire
  /// sur [center] : dès qu'il y en a au moins un, la caméra s'y ajuste.
  final List<LatLng>? fitPoints;

  static const String _tiles = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const String _userAgent = 'com.echango.echango_delivery';

  @override
  Widget build(BuildContext context) {
    final fit = (fitPoints != null && fitPoints!.isNotEmpty)
        ? CameraFit.coordinates(
            coordinates: fitPoints!,
            padding: const EdgeInsets.all(AppSpacing.xxl),
            // Sans plafond, un point unique remplit l'écran d'un zoom absurde.
            maxZoom: 15,
          )
        : null;

    return FlutterMap(
      options: MapOptions(
        // `initialCameraFit` l'emporte quand il est là ; `initialCenter` reste
        // exigé par l'API et sert de repli.
        initialCenter: center ?? fitPoints!.first,
        initialZoom: zoom,
        initialCameraFit: fit,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag,
        ),
      ),
      children: [
        TileLayer(urlTemplate: _tiles, userAgentPackageName: _userAgent),
        MarkerLayer(markers: markers),
      ],
    );
  }
}
