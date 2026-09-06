import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../config/api_config.dart';
import '../i18n/driver_strings.dart';
import '../state/locale_state.dart';
import '../theme/app_semantic_colors.dart';
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

  /// Le CDN public d'OSM par défaut, surchargeable au lancement — voir
  /// `ApiConfig.mapTileUrl`. Reste **une seule source pour toutes les cartes**
  /// (règle 5), maintenant tenue par la config plutôt que par une constante
  /// recopiable.
  static const String _tiles = ApiConfig.mapTileUrl;
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

/// Ce qu'un repère désigne. La convention est celle de Maps / Uber : le départ
/// est vert, la destination rouge, « moi » bleu — trois rôles qu'on ne
/// confond pas. Les teintes de MARQUE (`primary`, `tertiary`) ne portaient
/// aucun sens et changeaient avec le thème.
enum MapMarkerKind { pickup, dropoff, driver, stale }

/// L'icône et la couleur d'un rôle de repère — **la seule définition**.
///
/// `consultationMarker` la pose sur la carte, `MapLegend` en explique le sens
/// sous la carte : si l'un montrait un rond vert et l'autre nommait « rouge »,
/// la légende mentirait. Règle 5, critère « si l'un change, l'autre doit
/// changer » — donc une fonction, pas deux `switch` recopiés.
(IconData, Color) markerVisual(BuildContext context, MapMarkerKind kind) {
  final scheme = Theme.of(context).colorScheme;
  return switch (kind) {
    MapMarkerKind.pickup => (Icons.storefront, context.semantic.success),
    MapMarkerKind.dropoff => (Icons.location_on, scheme.error),
    MapMarkerKind.driver => (Icons.navigation, scheme.primary),
    MapMarkerKind.stale => (Icons.local_shipping, scheme.outline),
  };
}

/// Un repère de carte homogène : pastille blanche pour le détacher des tuiles,
/// icône colorée selon le rôle. Le même partout — on ne recopie plus un
/// `Marker` brut par écran (règle 6).
Marker consultationMarker(
  BuildContext context, {
  required LatLng at,
  required MapMarkerKind kind,
  VoidCallback? onTap,
  String? tooltip,
  bool selected = false,
  double size = 40,
}) {
  final scheme = Theme.of(context).colorScheme;
  final (icon, kindColor) = markerVisual(context, kind);
  // Sur une carte à plusieurs repères de même nature (la flotte), celui que la
  // fiche du bas décrit passe en couleur d'accent — sinon on ne sait pas
  // lequel on a touché.
  final color = selected ? scheme.tertiary : kindColor;

  Widget dot = Container(
    decoration: BoxDecoration(
      color: scheme.surface,
      shape: BoxShape.circle,
      border: Border.all(color: color, width: selected ? 3 : 2),
      boxShadow: const [
        BoxShadow(color: Colors.black26, blurRadius: 3, offset: Offset(0, 1)),
      ],
    ),
    alignment: Alignment.center,
    child: Icon(icon, color: color, size: size * 0.55),
  );

  if (tooltip != null) dot = Tooltip(message: tooltip, child: dot);
  if (onTap != null) dot = GestureDetector(onTap: onTap, child: dot);

  return Marker(point: at, width: size, height: size, child: dot);
}

/// Légende d'une carte de consultation : dit ce que chaque repère désigne.
/// Sans elle, deux pastilles de couleur sur des tuiles ne se lisent pas. Les
/// couleurs viennent de [markerVisual] — jamais recopiées ici.
class MapLegend extends StatelessWidget {
  const MapLegend({super.key, this.showDriver = false});

  /// `true` sur la carte « position du transporteur » côté commerçant, où un
  /// troisième repère — le transporteur — est présent.
  final bool showDriver;

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LocaleState>().locale;
    String t(String k) => driverLabel(k, locale);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Wrap(
        spacing: AppSpacing.md,
        runSpacing: AppSpacing.xs,
        children: [
          _LegendDot(kind: MapMarkerKind.pickup, label: t('driver.trip.legend.pickup')),
          _LegendDot(kind: MapMarkerKind.dropoff, label: t('driver.trip.legend.dropoff')),
          if (showDriver)
            _LegendDot(kind: MapMarkerKind.driver, label: t('driver.trip.legend.you')),
        ],
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.kind, required this.label});

  final MapMarkerKind kind;
  final String label;

  @override
  Widget build(BuildContext context) {
    final (_, color) = markerVisual(context, kind);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: AppSpacing.xs),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
