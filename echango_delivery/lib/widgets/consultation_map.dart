import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../config/api_config.dart';

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
/// ⚠️ **N'emploie que des API déjà éprouvées dans ce dépôt** (`MapOptions`,
/// `TileLayer`, `MarkerLayer`), celles de l'écran commerçant qui compile.
/// `CameraFit` cadrerait mieux une flotte dispersée, mais l'API de la version
/// épinglée n'est pas vérifiable ici — et ce projet a pour règle de vérifier
/// contre la version épinglée plutôt que de supposer.
class AppConsultationMap extends StatelessWidget {
  const AppConsultationMap({
    super.key,
    required this.center,
    required this.markers,
    this.zoom = 14,
  });

  final LatLng center;
  final List<Marker> markers;
  final double zoom;

  /// Le CDN public d'OSM par défaut, surchargeable au lancement — voir
  /// `ApiConfig.mapTileUrl`. Reste **une seule source pour toutes les cartes**
  /// (règle 5), maintenant tenue par la config plutôt que par une constante
  /// recopiable.
  static const String _tiles = ApiConfig.mapTileUrl;
  static const String _userAgent = 'com.echango.echango_delivery';

  @override
  Widget build(BuildContext context) {
    return FlutterMap(
      options: MapOptions(
        initialCenter: center,
        initialZoom: zoom,
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
