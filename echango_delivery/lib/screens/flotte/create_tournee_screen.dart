import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../i18n/fleet_strings.dart';
import '../../state/fleet_state.dart';
import '../../state/locale_state.dart';
import '../../theme/app_spacing.dart';
import '../../widgets/app_snack_bar.dart';
import '../commercant/map_picker_screen.dart';

/// Un choix de cible pour une tournée : un conducteur (flotte) ou un favori
/// (commerçant). `uuid == null` = diffusion large / décider plus tard.
typedef TourneeTarget = ({String? uuid, String label});

/// Un dépôt sélectionnable comme arrêt.
typedef TourneeDepotOption = ({String uuid, String name});

/// Ce qui change d'un persona à l'autre dans le composeur de tournée. Le
/// formulaire lui-même — arrêts, prix, colis, COD par arrêt — est identique
/// (règle 6), et ses libellés sont persona-neutres (`fleet.tournee.*`).
class TourneeComposerConfig {
  const TourneeComposerConfig({
    required this.depots,
    required this.targets,
    required this.targetLabel,
    required this.targetHint,
    required this.submit,
    required this.loadDependencies,
  });

  final List<TourneeDepotOption> depots;

  /// La première entrée est la cible « aucune » (diffusion / plus tard).
  final List<TourneeTarget> targets;
  final String targetLabel;
  final String targetHint;

  /// Envoie la tournée. Rend `null` en cas de succès, le message d'erreur
  /// traduit sinon.
  final Future<String?> Function(Map<String, dynamic> body) submit;

  final void Function(BuildContext context) loadDependencies;
}

/// Composer une **tournée multi-arrêt** (spec §4) : N arrêts en une commande,
/// un seul prix, un encaissement par arrêt.
///
/// Le demandeur compose **entièrement** la tournée ; le conducteur accepte ou
/// refuse en bloc. Deux arrêts minimum, au moins un enlèvement — le serveur
/// refuse le reste (`tournee.invalid_shape`), l'écran le dit avant l'envoi.
class TourneeComposerScreen extends StatefulWidget {
  const TourneeComposerScreen({super.key, required this.config});

  final TourneeComposerConfig config;

  @override
  State<TourneeComposerScreen> createState() => _TourneeComposerScreenState();
}

class _StopDraft {
  String type; // 'pickup' | 'dropoff'
  String? depotUuid;
  LatLng? point;
  String? city;
  String? neighborhood;
  String? province;
  final TextEditingController contactName = TextEditingController();
  final TextEditingController contactPhone = TextEditingController();
  final TextEditingController itemDesc = TextEditingController();
  final TextEditingController codAmount = TextEditingController();

  _StopDraft({required this.type});

  bool get isDepot => depotUuid != null;
  bool get hasLocation => depotUuid != null || point != null;

  void dispose() {
    contactName.dispose();
    contactPhone.dispose();
    itemDesc.dispose();
    codAmount.dispose();
  }
}

class _TourneeComposerScreenState extends State<TourneeComposerScreen> {
  String _t(String key) =>
      fleetLabel('fleet.tournee.$key', context.read<LocaleState>().locale);

  final _price = TextEditingController();
  final List<_StopDraft> _stops = [
    _StopDraft(type: 'pickup'),
    _StopDraft(type: 'dropoff'),
  ];
  String? _targetUuid;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.config.loadDependencies(context);
    });
  }

  @override
  void dispose() {
    _price.dispose();
    for (final s in _stops) {
      s.dispose();
    }
    super.dispose();
  }

  void _addStop() => setState(() => _stops.add(_StopDraft(type: 'dropoff')));

  void _removeStop(int index) {
    if (_stops.length <= 2) return;
    setState(() => _stops.removeAt(index).dispose());
  }

  Future<void> _pickOnMap(_StopDraft stop) async {
    final result = await Navigator.of(context).push<PickedLocation>(
      MaterialPageRoute(
        builder: (_) => MapPickerScreen(
          title: _t('stop.point'),
          initial: stop.point,
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      stop.depotUuid = null;
      stop.point = result.point;
      stop.city = result.city;
      stop.neighborhood = result.neighborhood;
      stop.province = result.province;
    });
  }

  Future<void> _submit() async {
    final price = double.tryParse(_price.text.trim());
    if (price == null || price <= 0) {
      showAppError(context, _t('price.required'));
      return;
    }
    if (_stops.length < 2) {
      showAppError(context, _t('min_stops'));
      return;
    }
    if (!_stops.any((s) => s.type == 'pickup')) {
      showAppError(context, _t('need_pickup'));
      return;
    }
    for (final s in _stops) {
      if (!s.hasLocation) {
        showAppError(context, _t('stop.location_required'));
        return;
      }
      if (!s.isDepot && s.contactName.text.trim().isEmpty) {
        showAppError(context, _t('stop.contact_required'));
        return;
      }
      if (s.codAmount.text.trim().isNotEmpty) {
        final cod = double.tryParse(s.codAmount.text.trim());
        if (cod == null || cod < 1) {
          showAppError(context, _t('stop.cod_invalid'));
          return;
        }
      }
    }

    final stopsBody = <Map<String, dynamic>>[];
    for (final s in _stops) {
      final cod = double.tryParse(s.codAmount.text.trim());
      final item = s.itemDesc.text.trim();
      stopsBody.add({
        'type': s.type,
        if (s.isDepot) 'depotUuid': s.depotUuid,
        if (!s.isDepot) ...{
          'latitude': s.point!.latitude,
          'longitude': s.point!.longitude,
          'contactName': s.contactName.text.trim(),
          if (s.contactPhone.text.trim().isNotEmpty)
            'contactPhone': s.contactPhone.text.trim(),
          if (s.city != null) 'city': s.city,
          if (s.province != null) 'province': s.province,
          if (s.neighborhood != null) 'neighborhood': s.neighborhood,
        },
        if (item.isNotEmpty)
          'items': [
            {'description': item, 'quantity': 1}
          ],
        if (cod != null && cod >= 1) 'codAmount': cod,
      });
    }

    setState(() => _saving = true);
    final error = await widget.config.submit({
      'price': price,
      'stops': stopsBody,
      if (_targetUuid != null) 'targetUuid': _targetUuid,
    });
    if (!mounted) return;
    if (error != null) {
      setState(() => _saving = false);
      showAppError(context, error);
      return;
    }
    Navigator.of(context).pop();
    showAppSnackBar(context, _t('created'));
  }

  @override
  Widget build(BuildContext context) {
    final depots = widget.config.depots;

    return Scaffold(
      appBar: AppBar(title: Text(_t('title'))),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          TextField(
            controller: _price,
            enabled: !_saving,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: _t('price'),
              helperText: _t('price.hint'),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          for (var i = 0; i < _stops.length; i++) _stopCard(i, _stops[i], depots),
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton.icon(
            onPressed: _saving ? null : _addStop,
            icon: const Icon(Icons.add),
            label: Text(_t('add_stop')),
          ),
          const SizedBox(height: AppSpacing.lg),
          DropdownButtonFormField<String?>(
            initialValue: _targetUuid,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: widget.config.targetLabel,
              helperText: widget.config.targetHint,
            ),
            items: [
              for (final target in widget.config.targets)
                DropdownMenuItem<String?>(
                  value: target.uuid,
                  child: Text(target.label, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged:
                _saving ? null : (v) => setState(() => _targetUuid = v),
          ),
          const SizedBox(height: AppSpacing.xxl),
          FilledButton(
            onPressed: _saving ? null : _submit,
            child: _saving
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(_t('submit')),
          ),
        ],
      ),
    );
  }

  Widget _stopCard(int index, _StopDraft stop, List<TourneeDepotOption> depots) {
    final isPickup = stop.type == 'pickup';
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  _t('stop').replaceFirst('%d', '${index + 1}'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                if (_stops.length > 2)
                  IconButton(
                    tooltip: _t('remove_stop'),
                    icon: const Icon(Icons.delete_outline),
                    onPressed: _saving ? null : () => _removeStop(index),
                  ),
              ],
            ),
            SegmentedButton<String>(
              segments: [
                ButtonSegment(value: 'pickup', label: Text(_t('pickup'))),
                ButtonSegment(value: 'dropoff', label: Text(_t('dropoff'))),
              ],
              selected: {stop.type},
              onSelectionChanged: _saving
                  ? null
                  : (v) => setState(() => stop.type = v.first),
            ),
            const SizedBox(height: AppSpacing.sm),
            if (depots.isNotEmpty)
              DropdownButtonFormField<String?>(
                initialValue: stop.depotUuid,
                isExpanded: true,
                decoration:
                    InputDecoration(labelText: _t('stop.depot')),
                items: [
                  DropdownMenuItem<String?>(
                    value: null,
                    child: Text(_t('stop.custom')),
                  ),
                  for (final d in depots)
                    DropdownMenuItem<String?>(
                      value: d.uuid,
                      child: Text(d.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: _saving
                    ? null
                    : (v) => setState(() {
                          stop.depotUuid = v;
                          if (v != null) stop.point = null;
                        }),
              ),
            if (!stop.isDepot) ...[
              const SizedBox(height: AppSpacing.sm),
              OutlinedButton.icon(
                onPressed: _saving ? null : () => _pickOnMap(stop),
                icon: Icon(stop.point == null
                    ? Icons.add_location_alt
                    : Icons.edit_location_alt),
                label: Text(
                  stop.point == null
                      ? _t('stop.set_point')
                      : [stop.neighborhood, stop.city, stop.province]
                          .whereType<String>()
                          .where((e) => e.trim().isNotEmpty)
                          .join(', ')
                          .ifEmpty(_t('stop.set_point')),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: stop.contactName,
                enabled: !_saving,
                decoration:
                    InputDecoration(labelText: _t('stop.contact_name')),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: stop.contactPhone,
                enabled: !_saving,
                keyboardType: TextInputType.phone,
                decoration:
                    InputDecoration(labelText: _t('stop.contact_phone')),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: stop.itemDesc,
              enabled: !_saving,
              decoration: InputDecoration(labelText: _t('stop.item')),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: stop.codAmount,
              enabled: !_saving,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: _t('stop.cod'),
                helperText: isPickup
                    ? _t('stop.cod.pickup_hint')
                    : _t('stop.cod.hint'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

extension _IfEmpty on String {
  String ifEmpty(String fallback) => trim().isEmpty ? fallback : this;
}

/// Composeur de tournée pour l'espace **flotte** : arrêts = ses dépôts, cible =
/// un de ses conducteurs.
class CreateTourneeScreen extends StatelessWidget {
  const CreateTourneeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<FleetState>();
    final locale = context.read<LocaleState>().locale;
    String t(String k) => fleetLabel('fleet.tournee.$k', locale);

    return TourneeComposerScreen(
      config: TourneeComposerConfig(
        depots: [
          for (final d in state.depots) (uuid: d.uuid, name: d.name),
        ],
        targets: [
          (uuid: null, label: t('driver.later')),
          for (final d in state.drivers)
            (
              uuid: d['uuid'] as String?,
              label: (d['name'] as String?) ?? '—',
            ),
        ],
        targetLabel: t('driver'),
        targetHint: t('driver.hint'),
        loadDependencies: (ctx) => ctx.read<FleetState>()
          ..load()
          ..loadDepots(),
        submit: (body) => context.read<FleetState>().createTournee(body),
      ),
    );
  }
}
