import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/driver_strings.dart';
import '../../models/driver_zone.dart';
import '../../services/bff_api_client.dart';
import '../../state/locale_state.dart';
import '../../theme/app_spacing.dart';
import '../../widgets/app_snack_bar.dart';
import '../../widgets/error_banner.dart';
import '../../widgets/section_card.dart';

/// Où ce transporteur veut voir des courses : un point de base et un rayon.
///
/// ── Ce que cet écran doit rendre évident, sous peine d'être nuisible ───────
///
/// - **sans point de base, la liste des opportunités est VIDE** — c'est un
///   changement par rapport à la wilaya (dont l'absence montrait tout). L'écran
///   doit donc inviter à en poser un, pas laisser croire à une panne.
/// - **le réglage se défait**, et le bouton pour le faire est visible dès qu'un
///   point de base existe.
/// - **la position GPS pré-remplit, elle ne filtre pas.** C'est le point
///   enregistré qui filtre — un point sauvegardé ne dépend pas du tracking.
class ZoneCard extends StatefulWidget {
  const ZoneCard({super.key});

  @override
  State<ZoneCard> createState() => _ZoneCardState();
}

class _ZoneCardState extends State<ZoneCard> {
  final _lat = TextEditingController();
  final _lng = TextEditingController();
  final _radius = TextEditingController();

  DriverZone? _zone;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  String _d(String key, [Map<String, String>? vars]) =>
      driverLabel(key, context.read<LocaleState>().locale, vars);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _lat.dispose();
    _lng.dispose();
    _radius.dispose();
    super.dispose();
  }

  void _fill(DriverZone zone) {
    _lat.text = zone.center?.latitude.toString() ?? '';
    _lng.text = zone.center?.longitude.toString() ?? '';
    _radius.text = '${zone.radiusKm ?? zone.suggestedRadiusKm}';
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final zone = await context.read<BffApiClient>().getZone();
      if (!mounted) return;
      setState(() {
        _zone = zone;
        _fill(zone);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _d('driver.zone.load_failed');
        _loading = false;
      });
    }
  }

  void _usePosition() {
    final pos = _zone?.position;
    if (pos == null) return;
    setState(() {
      _lat.text = pos.latitude.toString();
      _lng.text = pos.longitude.toString();
    });
  }

  Future<void> _save({required bool clear}) async {
    final lat = double.tryParse(_lat.text.trim());
    final lng = double.tryParse(_lng.text.trim());
    if (!clear && (lat == null) != (lng == null)) {
      showAppError(context, _d('driver.zone.center_incomplete'));
      return;
    }

    setState(() => _saving = true);
    try {
      final zone = await context.read<BffApiClient>().setZone(
            centerLat: clear ? null : lat,
            centerLng: clear ? null : lng,
            radiusKm: clear ? null : int.tryParse(_radius.text.trim()),
          );
      if (!mounted) return;
      setState(() {
        _zone = zone;
        _fill(zone);
        _saving = false;
      });
      // Relu depuis la réponse du serveur, jamais depuis la saisie : c'est lui
      // qui a le dernier mot, et un refus silencieux se verrait ici.
      showAppSnackBar(
          context, _d(clear ? 'driver.zone.cleared' : 'driver.zone.saved'));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showAppError(context, _d('driver.zone.save_failed'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final zone = _zone;

    return AppSectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_d('driver.zone.title'),
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.xs),
          Text(
            _d('driver.zone.subtitle'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpacing.md),

          if (_error != null) ...[
            AppErrorBanner(message: _error!),
            const SizedBox(height: AppSpacing.md),
          ],

          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            Text(_d('driver.zone.center'),
                style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: AppSpacing.xs),
            Text(_d('driver.zone.center.hint'),
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _lat,
                    enabled: !_saving,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true, signed: true),
                    decoration: InputDecoration(
                      labelText: _d('driver.zone.lat'),
                      prefixIcon: const Icon(Icons.my_location_outlined),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: TextField(
                    controller: _lng,
                    enabled: !_saving,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true, signed: true),
                    decoration: InputDecoration(
                      labelText: _d('driver.zone.lng'),
                    ),
                  ),
                ),
              ],
            ),
            if (zone?.positionKnown == true) ...[
              const SizedBox(height: AppSpacing.sm),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: _saving ? null : _usePosition,
                  icon: const Icon(Icons.gps_fixed, size: 18),
                  label: Text(_d('driver.zone.use_position')),
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.lg),

            TextField(
              controller: _radius,
              enabled: !_saving,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: _d('driver.zone.radius'),
                helperText: _d('driver.zone.radius.hint'),
                helperMaxLines: 3,
                prefixIcon: const Icon(Icons.social_distance_outlined),
                suffixText: _d('driver.zone.km'),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),

            // Dire l'état courant en une phrase, plutôt que de le laisser
            // déduire de trois champs : c'est cette phrase qui empêche de
            // prendre une liste vide pour une panne.
            Text(
              zone == null || !zone.anchorSet
                  ? _d('driver.zone.state.none')
                  : _d('driver.zone.state.active', {
                      'radius': '${zone.radiusKm ?? zone.suggestedRadiusKm}',
                    }),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.md),

            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: _saving ? null : () => _save(clear: false),
                    child: _saving
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(_d('driver.zone.save')),
                  ),
                ),
                // Le retrait n'apparaît que s'il y a quelque chose à retirer.
                if (zone != null && !zone.isUnset) ...[
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _saving ? null : () => _save(clear: true),
                      child: Text(_d('driver.zone.clear')),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}
