import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../models/merchant_order.dart';
import '../../services/bff_api_client.dart';

/// Sélection d'un point sur la carte, avec recherche d'adresse.
///
/// ── Pourquoi cet écran existe ───────────────────────────────────────────────
///
/// Toute adresse saisie librement tombait jusqu'ici au **centre d'Alger** : le
/// dispatch géospatial de Fleetbase choisissait donc le transporteur le plus
/// proche d'un point faux, et deux livraisons à l'opposé de la ville avaient
/// exactement les mêmes coordonnées. Un formulaire texte ne peut pas produire
/// une position ; seule une carte ou un géocodage le peut.
///
/// ── OpenStreetMap plutôt que Google Maps ────────────────────────────────────
///
/// Pas de clé API, pas de facturation au chargement, et cohérent avec le choix
/// d'auto-héberger Fleetbase. ⚠️ Les tuiles publiques d'OSM sont prévues pour
/// un trafic modeste : convenables pour le pilote, à remplacer par une instance
/// dédiée ou un fournisseur de tuiles avant un usage réel.
class MapPickerScreen extends StatefulWidget {
  /// Point de départ de la carte — l'adresse déjà saisie, si elle existe.
  final LatLng? initial;

  /// Titre, pour que le commerçant sache lequel des deux points il place.
  final String title;

  const MapPickerScreen({super.key, this.initial, required this.title});

  @override
  State<MapPickerScreen> createState() => _MapPickerScreenState();
}

/// Ce que l'écran renvoie : un point ET son libellé, résolus ensemble.
class PickedLocation {
  final LatLng point;
  final String label;
  final String? city;

  const PickedLocation({required this.point, required this.label, this.city});
}

class _MapPickerScreenState extends State<MapPickerScreen> {
  /// Centre d'Alger — point de départ de la carte quand rien n'est connu.
  /// Contrairement à l'ancien comportement, ce n'est plus la valeur *envoyée* :
  /// le commerçant doit déplacer le repère, et c'est sa position qui compte.
  static const _algiers = LatLng(36.7538, 3.0588);

  final _mapController = MapController();
  final _searchController = TextEditingController();

  late LatLng _selected;
  String _label = '';
  String? _city;
  bool _resolving = false;
  List<GeocodedPlace> _suggestions = [];
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _selected = widget.initial ?? _algiers;
    // Après le premier rendu : `_resolveLabel` appelle `setState`, interdit
    // pendant `initState`. Le résoudre tout de suite reste nécessaire — le
    // commerçant doit voir à quoi correspond le point avant de le déplacer.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _resolveLabel();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _resolveLabel() async {
    setState(() => _resolving = true);
    try {
      final place = await context
          .read<BffApiClient>()
          .reverseGeocode(_selected.latitude, _selected.longitude);
      if (!mounted) return;
      setState(() {
        _label = place.label;
        _city = place.city;
      });
    } catch (_) {
      // Le point reste parfaitement valide sans libellé : c'est lui que le
      // dispatch utilise. Échouer ici bloquerait la sélection pour un confort.
      if (mounted) setState(() => _label = '');
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  /// Recherche différée : sans ce délai, chaque frappe consommerait un appel du
  /// quota partagé de Nominatim, que le BFF sérialise à une par seconde.
  void _onSearchChanged(String value) {
    _debounce?.cancel();
    if (value.trim().length < 3) {
      setState(() => _suggestions = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 600), () => _search(value));
  }

  Future<void> _search(String value) async {
    try {
      final results = await context.read<BffApiClient>().searchAddress(value);
      if (mounted) setState(() => _suggestions = results);
    } catch (_) {
      if (mounted) setState(() => _suggestions = []);
    }
  }

  void _applySuggestion(GeocodedPlace place) {
    final point = LatLng(place.latitude, place.longitude);
    setState(() {
      _selected = point;
      _label = place.label;
      _city = place.city;
      _suggestions = [];
      _searchController.clear();
    });
    _mapController.move(point, 16);
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(
        children: [
          _searchField(),
          if (_suggestions.isNotEmpty) _suggestionList(),
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _selected,
                    initialZoom: 15,
                    // Le repère reste au centre et c'est la carte qui bouge :
                    // le doigt ne masque jamais le point qu'on vise, ce qu'un
                    // marqueur déplaçable au toucher fait systématiquement.
                    onPositionChanged: (position, hasGesture) {
                      if (hasGesture) _selected = position.center;
                    },
                    onMapEvent: (event) {
                      if (event is MapEventMoveEnd) _resolveLabel();
                    },
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      // Exigé par la politique d'usage des tuiles OSM.
                      userAgentPackageName: 'com.echango.echango_delivery',
                    ),
                  ],
                ),
                // Repère fixe, ancré sur le centre exact de la carte.
                Padding(
                  padding: const EdgeInsets.only(bottom: 36),
                  child: Icon(Icons.location_on,
                      size: 44, color: theme.colorScheme.error),
                ),
              ],
            ),
          ),
          _footer(theme),
        ],
      ),
    );
  }

  Widget _searchField() => Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(
          controller: _searchController,
          onChanged: _onSearchChanged,
          decoration: const InputDecoration(
            hintText: 'Rechercher une adresse…',
            prefixIcon: Icon(Icons.search),
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
      );

  Widget _suggestionList() => ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 220),
        child: Card(
          margin: const EdgeInsets.symmetric(horizontal: 12),
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: _suggestions.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final place = _suggestions[i];
              return ListTile(
                dense: true,
                leading: const Icon(Icons.place_outlined),
                title: Text(place.shortLabel),
                subtitle: Text(
                  place.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => _applySuggestion(place),
              );
            },
          ),
        ),
      );

  Widget _footer(ThemeData theme) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.place_outlined, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _resolving
                        ? Text('Recherche de l\'adresse…',
                            style: theme.textTheme.bodySmall)
                        : Text(
                            _label.isEmpty
                                ? 'Point sans adresse connue — la position est '
                                    'tout de même utilisable'
                                : _label,
                            style: theme.textTheme.bodySmall,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: () => Navigator.pop(
                  context,
                  PickedLocation(point: _selected, label: _label, city: _city),
                ),
                icon: const Icon(Icons.check),
                label: const Text('Valider ce point'),
              ),
            ],
          ),
        ),
      );
}
