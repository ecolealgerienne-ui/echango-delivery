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

/// Où ce transporteur veut voir des courses.
///
/// ── Ce que cet écran doit rendre évident, sous peine d'être nuisible ───────
///
/// Un filtre **retire** des courses de la liste. Mal compris, il fait croire à
/// une panne : le transporteur ouvre l'application, voit peu ou rien, et n'a
/// aucun moyen de deviner que c'est lui qui l'a demandé. Trois partis pris en
/// découlent, et ils comptent plus que la mise en page :
///
/// - **rien n'est filtré tant qu'il n'a rien choisi.** Le rayon proposé (15 km)
///   pré-remplit le champ, il ne s'applique pas. Un défaut appliqué en silence
///   ferait disparaître du travail pour quelqu'un qui n'a jamais ouvert ce
///   réglage.
/// - **le réglage se défait**, et le bouton pour le faire est visible dès qu'un
///   filtre existe. Un réglage qu'on ne peut pas annuler est un piège.
/// - **l'écran dit quand le rayon n'agit pas.** Sans position connue, il ne
///   filtre rien ; le taire laisserait croire à un filtre actif et rendrait
///   incompréhensible le nombre de courses affichées.
class ZoneCard extends StatefulWidget {
  const ZoneCard({super.key});

  @override
  State<ZoneCard> createState() => _ZoneCardState();
}

class _ZoneCardState extends State<ZoneCard> {
  final _wilaya = TextEditingController();
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
    _wilaya.dispose();
    _radius.dispose();
    super.dispose();
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
        _wilaya.text = zone.wilaya ?? '';
        // ⚠️ Le champ est **pré-rempli** avec la proposition quand rien n'est
        // choisi — mais tant que le transporteur n'enregistre pas, aucun
        // filtrage n'a lieu. Le texte sous le champ le dit explicitement.
        _radius.text = '${zone.radiusKm ?? zone.suggestedRadiusKm}';
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

  Future<void> _save({required bool clear}) async {
    setState(() => _saving = true);
    try {
      final wilaya = _wilaya.text.trim();
      final radius = int.tryParse(_radius.text.trim());
      final zone = await context.read<BffApiClient>().setZone(
            wilaya: clear || wilaya.isEmpty ? null : wilaya,
            radiusKm: clear ? null : radius,
          );
      if (!mounted) return;
      setState(() {
        _zone = zone;
        _wilaya.text = zone.wilaya ?? '';
        _radius.text = '${zone.radiusKm ?? zone.suggestedRadiusKm}';
        _saving = false;
      });
      // Relu depuis la réponse du serveur, jamais depuis la saisie : c'est lui
      // qui a le dernier mot, et un refus silencieux se verrait ici.
      showAppSnackBar(context, _d(clear ? 'driver.zone.cleared' : 'driver.zone.saved'));
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
            TextField(
              controller: _wilaya,
              enabled: !_saving,
              decoration: InputDecoration(
                labelText: _d('driver.zone.wilaya'),
                helperText: _d('driver.zone.wilaya.hint'),
                helperMaxLines: 2,
                prefixIcon: const Icon(Icons.map_outlined),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            TextField(
              controller: _radius,
              enabled: !_saving,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: _d('driver.zone.radius'),
                // ⚠️ Le texte d'aide **change** selon que la position est
                // connue : annoncer un rayon qui ne filtre rien rendrait le
                // nombre de courses affichées incompréhensible.
                helperText: zone?.positionKnown == false
                    ? _d('driver.zone.radius.no_position')
                    : _d('driver.zone.radius.hint'),
                helperMaxLines: 3,
                prefixIcon: const Icon(Icons.social_distance_outlined),
                suffixText: _d('driver.zone.km'),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),

            // Dire l'état courant en une phrase, plutôt que de le laisser
            // déduire de deux champs : c'est cette phrase qui empêche de
            // prendre un filtre pour une panne.
            Text(
              zone == null || zone.isUnset
                  ? _d('driver.zone.state.none')
                  : _d('driver.zone.state.active', {
                      'wilaya': zone.wilaya ?? _d('driver.zone.all_wilayas'),
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
                // Le retrait n'apparaît que s'il y a quelque chose à retirer —
                // un bouton « tout voir » sur un écran qui ne filtre rien ne
                // ferait qu'ajouter une question.
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
