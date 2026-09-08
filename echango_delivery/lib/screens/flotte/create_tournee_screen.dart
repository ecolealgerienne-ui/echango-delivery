import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../i18n/fleet_strings.dart';
import '../../models/fleet_depot.dart';
import '../../state/fleet_state.dart';
import '../../state/locale_state.dart';
import '../../theme/app_spacing.dart';
import '../../widgets/app_snack_bar.dart';
import '../commercant/map_picker_screen.dart';

/// Composer une **tournée multi-arrêt** (spec §4) : N arrêts en une commande,
/// un seul prix, un encaissement par arrêt.
///
/// ── Ce que l'écran laisse faire, et ce qu'il impose ──────────────────────
///
/// Le demandeur compose **entièrement** la tournée : liste ordonnée d'arrêts
/// (un dépôt à lui, ou une adresse pointée sur la carte), le type de chaque
/// arrêt (enlèvement / livraison), les colis, un COD par arrêt, un prix unique.
/// Le conducteur accepte ou refuse **en bloc** — il n'y a pas de composition
/// côté conducteur, donc rien de tel ici non plus.
///
/// Deux arrêts minimum, au moins un enlèvement : le serveur refuse le reste
/// (`tournee.invalid_shape`), l'écran le dit avant l'envoi pour épargner
/// l'aller-retour.
class CreateTourneeScreen extends StatefulWidget {
  const CreateTourneeScreen({super.key});

  @override
  State<CreateTourneeScreen> createState() => _CreateTourneeScreenState();
}

/// L'état d'un arrêt en cours de saisie. Soit [depotUuid] est posé (arrêt =
/// un dépôt du transporteur), soit [point] l'est (adresse pointée).
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

class _CreateTourneeScreenState extends State<CreateTourneeScreen> {
  String _t(String key) => fleetLabel(key, context.read<LocaleState>().locale);

  final _price = TextEditingController();
  final List<_StopDraft> _stops = [
    _StopDraft(type: 'pickup'),
    _StopDraft(type: 'dropoff'),
  ];
  String? _driverUuid;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<FleetState>()
        ..load()
        ..loadDepots();
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
    setState(() {
      _stops.removeAt(index).dispose();
    });
  }

  Future<void> _pickOnMap(_StopDraft stop) async {
    final result = await Navigator.of(context).push<PickedLocation>(
      MaterialPageRoute(
        builder: (_) => MapPickerScreen(
          title: _t('fleet.tournee.stop.point'),
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
      showAppError(context, _t('fleet.tournee.price.required'));
      return;
    }
    if (_stops.length < 2) {
      showAppError(context, _t('fleet.tournee.min_stops'));
      return;
    }
    if (!_stops.any((s) => s.type == 'pickup')) {
      showAppError(context, _t('fleet.tournee.need_pickup'));
      return;
    }
    for (var i = 0; i < _stops.length; i++) {
      final s = _stops[i];
      if (!s.hasLocation) {
        showAppError(context, _t('fleet.tournee.stop.location_required'));
        return;
      }
      if (!s.isDepot && s.contactName.text.trim().isEmpty) {
        showAppError(context, _t('fleet.tournee.stop.contact_required'));
        return;
      }
      if (s.codAmount.text.trim().isNotEmpty) {
        final cod = double.tryParse(s.codAmount.text.trim());
        if (cod == null || cod < 1) {
          showAppError(context, _t('fleet.tournee.stop.cod_invalid'));
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
    final error = await context.read<FleetState>().createTournee({
      'price': price,
      'stops': stopsBody,
      if (_driverUuid != null) 'targetUuid': _driverUuid,
    });
    if (!mounted) return;
    if (error != null) {
      setState(() => _saving = false);
      showAppError(context, error);
      return;
    }
    Navigator.of(context).pop();
    showAppSnackBar(context, _t('fleet.tournee.created'));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<FleetState>();
    final depots = state.depots;
    final drivers = state.drivers;

    return Scaffold(
      appBar: AppBar(title: Text(_t('fleet.tournee.title'))),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          TextField(
            controller: _price,
            enabled: !_saving,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: _t('fleet.tournee.price'),
              helperText: _t('fleet.tournee.price.hint'),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          for (var i = 0; i < _stops.length; i++)
            _stopCard(i, _stops[i], depots),
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton.icon(
            onPressed: _saving ? null : _addStop,
            icon: const Icon(Icons.add),
            label: Text(_t('fleet.tournee.add_stop')),
          ),
          const SizedBox(height: AppSpacing.lg),
          DropdownButtonFormField<String?>(
            initialValue: _driverUuid,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: _t('fleet.tournee.driver'),
              helperText: _t('fleet.tournee.driver.hint'),
            ),
            items: [
              DropdownMenuItem<String?>(
                value: null,
                child: Text(_t('fleet.tournee.driver.later')),
              ),
              for (final d in drivers)
                DropdownMenuItem<String?>(
                  value: d['uuid'] as String?,
                  child: Text((d['name'] as String?) ?? '—',
                      overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: _saving ? null : (v) => setState(() => _driverUuid = v),
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
                : Text(_t('fleet.tournee.submit')),
          ),
        ],
      ),
    );
  }

  Widget _stopCard(int index, _StopDraft stop, List<FleetDepot> depots) {
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
                  _t('fleet.tournee.stop').replaceFirst('%d', '${index + 1}'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                if (_stops.length > 2)
                  IconButton(
                    tooltip: _t('fleet.tournee.remove_stop'),
                    icon: const Icon(Icons.delete_outline),
                    onPressed: _saving ? null : () => _removeStop(index),
                  ),
              ],
            ),
            SegmentedButton<String>(
              segments: [
                ButtonSegment(
                    value: 'pickup', label: Text(_t('fleet.tournee.pickup'))),
                ButtonSegment(
                    value: 'dropoff', label: Text(_t('fleet.tournee.dropoff'))),
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
                decoration: InputDecoration(
                  labelText: _t('fleet.tournee.stop.depot'),
                ),
                items: [
                  DropdownMenuItem<String?>(
                    value: null,
                    child: Text(_t('fleet.tournee.stop.custom')),
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
                      ? _t('fleet.tournee.stop.set_point')
                      : [stop.neighborhood, stop.city, stop.province]
                          .whereType<String>()
                          .where((e) => e.trim().isNotEmpty)
                          .join(', ')
                          .ifEmpty(_t('fleet.tournee.stop.set_point')),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: stop.contactName,
                enabled: !_saving,
                decoration: InputDecoration(
                    labelText: _t('fleet.tournee.stop.contact_name')),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: stop.contactPhone,
                enabled: !_saving,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                    labelText: _t('fleet.tournee.stop.contact_phone')),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: stop.itemDesc,
              enabled: !_saving,
              decoration:
                  InputDecoration(labelText: _t('fleet.tournee.stop.item')),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: stop.codAmount,
              enabled: !_saving,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: _t('fleet.tournee.stop.cod'),
                helperText: isPickup
                    ? _t('fleet.tournee.stop.cod.pickup_hint')
                    : _t('fleet.tournee.stop.cod.hint'),
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
