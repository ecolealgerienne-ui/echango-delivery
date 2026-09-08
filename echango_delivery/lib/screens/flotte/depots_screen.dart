import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../i18n/fleet_strings.dart';
import '../../models/fleet_depot.dart';
import '../../state/fleet_state.dart';
import '../../state/locale_state.dart';
import '../../theme/app_spacing.dart';
import '../../widgets/app_snack_bar.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/empty_state.dart';
import '../commercant/map_picker_screen.dart';

/// Les dépôts d'un transporteur national (spec §3.1).
///
/// Côté Fleetbase, chacun est un `Place` possédé par le `Vendor` du
/// transporteur, marqué `meta.is_depot` — le patron exact du carnet d'adresses
/// commerçant (`AddressesScreen`), dont cet écran reprend la forme.
///
/// ── Trois états, pas deux ────────────────────────────────────────────────
///
/// `loadDepots` avale son erreur (pour ne pas faire remonter d'exception nue)
/// et laisse la liste vide. Une liste vide peut alors vouloir dire « je n'ai
/// pas pu lire » — l'annoncer « aucun dépôt » serait faux, définitif, et
/// pousserait à ressaisir. `depotsUnavailable` distingue les deux (règle 10).
class DepotsScreen extends StatefulWidget {
  const DepotsScreen({super.key});

  @override
  State<DepotsScreen> createState() => _DepotsScreenState();
}

class _DepotsScreenState extends State<DepotsScreen> {
  String _t(String key) =>
      fleetLabel(key, context.read<LocaleState>().locale);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<FleetState>().loadDepots();
    });
  }

  Future<void> _openForm(FleetDepot? existing) async {
    final state = context.read<FleetState>();
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ChangeNotifierProvider<FleetState>.value(
          value: state,
          child: _DepotFormScreen(existing: existing),
        ),
      ),
    );
  }

  Future<void> _ship(FleetDepot d) async {
    final state = context.read<FleetState>();
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ChangeNotifierProvider<FleetState>.value(
          value: state,
          child: _ShipFromDepotScreen(depot: d),
        ),
      ),
    );
  }

  Future<void> _delete(FleetDepot d) async {
    final ok = await AppConfirmDialog.destructive(
      context,
      message: _t('fleet.depots.delete.confirm'),
      confirmLabel: _t('fleet.depots.delete'),
      cancelLabel: _t('fleet.cancel'),
    );
    if (!ok || !mounted) return;
    final error = await context.read<FleetState>().deleteDepot(d.uuid);
    if (!mounted) return;
    showAppOutcome(context, error, _t('fleet.depots.deleted'));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<FleetState>();

    return Scaffold(
      appBar: AppBar(title: Text(_t('fleet.depots.title'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openForm(null),
        icon: const Icon(Icons.add),
        label: Text(_t('fleet.depots.add')),
      ),
      body: _body(state),
    );
  }

  Widget _body(FleetState state) {
    if (state.depotsLoading && state.depots.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.depotsUnavailable) {
      return AppEmptyState.unavailable(
        title: _t('fleet.depots.unavailable'),
        hint: _t('fleet.depots.unavailable.hint'),
        scrollable: false,
        onRetry: () => context.read<FleetState>().loadDepots(),
      );
    }
    if (state.depots.isEmpty) {
      return AppEmptyState(
        icon: Icons.warehouse_outlined,
        title: _t('fleet.depots.empty'),
        hint: _t('fleet.depots.empty.hint'),
        scrollable: false,
      );
    }

    return RefreshIndicator(
      onRefresh: () => context.read<FleetState>().loadDepots(),
      child: ListView.builder(
        padding: const EdgeInsets.all(AppSpacing.sm),
        itemCount: state.depots.length,
        itemBuilder: (_, i) {
          final d = state.depots[i];
          return Card(
            margin: const EdgeInsets.symmetric(vertical: 6),
            child: ListTile(
              leading: const Icon(Icons.warehouse_outlined),
              title: Text(d.name),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    [d.locationLabel, d.contactName, d.phone]
                        .where((e) => e != null && e.toString().trim().isNotEmpty)
                        .join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (!d.hasPosition)
                    Text(
                      _t('fleet.depots.no_position'),
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
              onTap: () => _openForm(d),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (d.hasPosition)
                    IconButton(
                      icon: const Icon(Icons.local_shipping_outlined),
                      tooltip: _t('fleet.depots.ship'),
                      onPressed: () => _ship(d),
                    ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: _t('fleet.depots.delete'),
                    onPressed: () => _delete(d),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Le formulaire d'un dépôt — création ou modification, le même écran.
///
/// La **position est obligatoire** (contrairement au carnet d'adresses
/// commerçant) : `SaveDepotDto` exige `latitude`/`longitude`, et un dépôt sans
/// point ne peut être ni une origine ni une destination de course.
class _DepotFormScreen extends StatefulWidget {
  const _DepotFormScreen({this.existing});

  final FleetDepot? existing;

  @override
  State<_DepotFormScreen> createState() => _DepotFormScreenState();
}

class _DepotFormScreenState extends State<_DepotFormScreen> {
  String _t(String key) =>
      fleetLabel(key, context.read<LocaleState>().locale);

  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _contact = TextEditingController();

  LatLng? _point;
  // Composantes du géocodage inverse — jamais saisies à la main. Restent nulles
  // sur une modification sans repasser par la carte : le serveur ne touche pas
  // aux clés absentes du corps, donc ce qu'un passage précédent a établi survit.
  String? _city;
  String? _neighborhood;
  String? _province;
  String? _postalCode;
  bool _saving = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final d = widget.existing;
    if (d == null) return;
    _name.text = d.name;
    _phone.text = d.phone ?? '';
    _contact.text = d.contactName ?? '';
    _city = d.city;
    _neighborhood = d.neighborhood;
    _province = d.province;
    _postalCode = d.postalCode;
    if (d.hasPosition) _point = LatLng(d.latitude!, d.longitude!);
  }

  @override
  void dispose() {
    for (final c in [_name, _phone, _contact]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickOnMap() async {
    final result = await Navigator.of(context).push<PickedLocation>(
      MaterialPageRoute(
        builder: (_) => MapPickerScreen(
          title: _t('fleet.depots.position.title'),
          initial: _point,
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _point = result.point;
      _city = result.city;
      _neighborhood = result.neighborhood;
      _province = result.province;
      _postalCode = result.postalCode;
    });
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final phone = _phone.text.trim();
    final contact = _contact.text.trim();

    if (name.isEmpty) {
      showAppError(context, _t('fleet.depots.name.required'));
      return;
    }
    if (phone.isEmpty) {
      showAppError(context, _t('fleet.depots.phone.required'));
      return;
    }
    if (contact.isEmpty) {
      showAppError(context, _t('fleet.depots.contact.required'));
      return;
    }
    if (_point == null) {
      showAppError(context, _t('fleet.depots.position.missing'));
      return;
    }

    setState(() => _saving = true);
    final error = await context.read<FleetState>().saveDepot(
          id: widget.existing?.uuid,
          name: name,
          latitude: _point!.latitude,
          longitude: _point!.longitude,
          phone: phone,
          contactName: contact,
          city: _city,
          neighborhood: _neighborhood,
          province: _province,
          postalCode: _postalCode,
        );
    if (!mounted) return;
    if (error != null) {
      setState(() => _saving = false);
      showAppError(context, error);
      return;
    }
    Navigator.of(context).pop();
    showAppSnackBar(context, _t('fleet.depots.saved'));
  }

  @override
  Widget build(BuildContext context) {
    final placed = _point != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(_t(_isEdit ? 'fleet.depots.title' : 'fleet.depots.add')),
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          TextField(
            controller: _name,
            enabled: !_saving,
            decoration: InputDecoration(labelText: _t('fleet.depots.name')),
          ),
          const SizedBox(height: AppSpacing.lg),
          TextField(
            controller: _phone,
            enabled: !_saving,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(labelText: _t('fleet.depots.phone')),
          ),
          const SizedBox(height: AppSpacing.lg),
          TextField(
            controller: _contact,
            enabled: !_saving,
            decoration: InputDecoration(labelText: _t('fleet.depots.contact')),
          ),
          const SizedBox(height: AppSpacing.lg),
          OutlinedButton.icon(
            onPressed: _saving ? null : _pickOnMap,
            icon: Icon(placed ? Icons.edit_location_alt : Icons.add_location_alt),
            label: Text(
              placed
                  ? [_neighborhood, _city, _province]
                      .whereType<String>().where((e) => e.trim().isNotEmpty)
                      .join(', ')
                      .ifEmpty(_t('fleet.depots.position'))
                  : _t('fleet.depots.position.set'),
            ),
          ),
          if (!placed) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              _t('fleet.depots.position.missing'),
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.xxl),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(_t('fleet.depots.save')),
          ),
        ],
      ),
    );
  }
}

/// Créer une course **depuis un dépôt** vers un client (spec §3.3).
///
/// Formulaire volontairement simple, distinct de l'écran de commande du
/// commerçant : l'origine est fixée (le dépôt), et le transporteur paie —
/// `price` est obligatoire. L'encaissement est autorisé (son client règle à la
/// porte). Il peut assigner d'emblée un de ses conducteurs, ou laisser la
/// course confiée et l'affecter ensuite.
class _ShipFromDepotScreen extends StatefulWidget {
  const _ShipFromDepotScreen({required this.depot});

  final FleetDepot depot;

  @override
  State<_ShipFromDepotScreen> createState() => _ShipFromDepotScreenState();
}

class _ShipFromDepotScreenState extends State<_ShipFromDepotScreen> {
  String _t(String key) =>
      fleetLabel(key, context.read<LocaleState>().locale);

  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _itemDesc = TextEditingController();
  final _price = TextEditingController();
  final _codAmount = TextEditingController();

  LatLng? _point;
  String? _city;
  String? _neighborhood;
  String? _province;
  bool _cod = false;
  String? _driverUuid;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<FleetState>().load();
    });
  }

  @override
  void dispose() {
    for (final c in [_name, _phone, _itemDesc, _price, _codAmount]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickOnMap() async {
    final result = await Navigator.of(context).push<PickedLocation>(
      MaterialPageRoute(
        builder: (_) => MapPickerScreen(
          title: _t('fleet.ship.dropoff.title'),
          initial: _point,
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _point = result.point;
      _city = result.city;
      _neighborhood = result.neighborhood;
      _province = result.province;
    });
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    final phone = _phone.text.trim();
    final price = double.tryParse(_price.text.trim());
    final cod = _cod ? double.tryParse(_codAmount.text.trim()) : null;

    if (name.isEmpty) {
      showAppError(context, _t('fleet.ship.name.required'));
      return;
    }
    if (phone.isEmpty) {
      showAppError(context, _t('fleet.ship.phone.required'));
      return;
    }
    if (_point == null) {
      showAppError(context, _t('fleet.ship.point.required'));
      return;
    }
    if (price == null || price <= 0) {
      showAppError(context, _t('fleet.ship.price.required'));
      return;
    }
    if (_cod && (cod == null || cod < 1)) {
      showAppError(context, _t('fleet.ship.cod.required'));
      return;
    }

    setState(() => _saving = true);
    final error = await context.read<FleetState>().createFleetOrderFromDepot({
      'pickupDepotUuid': widget.depot.uuid,
      'dropoffLocationName': name,
      'dropoffLatitude': _point!.latitude,
      'dropoffLongitude': _point!.longitude,
      if (_city != null) 'dropoffCity': _city,
      if (_province != null) 'dropoffProvince': _province,
      if (_neighborhood != null) 'dropoffNeighborhood': _neighborhood,
      'dropoffContactName': name,
      'dropoffContactPhone': phone,
      if (_itemDesc.text.trim().isNotEmpty)
        'items': [
          {'description': _itemDesc.text.trim(), 'quantity': 1}
        ],
      'price': price,
      if (_cod && cod != null) ...{
        'codAmount': cod,
        'codIncludesDelivery': false,
      },
      if (_driverUuid != null) 'targetDriverUuid': _driverUuid,
    });
    if (!mounted) return;
    if (error != null) {
      setState(() => _saving = false);
      showAppError(context, error);
      return;
    }
    Navigator.of(context).pop();
    showAppSnackBar(context, _t('fleet.ship.created'));
  }

  @override
  Widget build(BuildContext context) {
    final drivers = context.watch<FleetState>().drivers;

    return Scaffold(
      appBar: AppBar(title: Text(_t('fleet.ship.title'))),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.warehouse_outlined),
              title: Text(_t('fleet.ship.from', )),
              subtitle: Text(widget.depot.name),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          TextField(
            controller: _name,
            enabled: !_saving,
            decoration: InputDecoration(labelText: _t('fleet.ship.client.name')),
          ),
          const SizedBox(height: AppSpacing.lg),
          TextField(
            controller: _phone,
            enabled: !_saving,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(labelText: _t('fleet.ship.client.phone')),
          ),
          const SizedBox(height: AppSpacing.lg),
          OutlinedButton.icon(
            onPressed: _saving ? null : _pickOnMap,
            icon: Icon(_point == null ? Icons.add_location_alt : Icons.edit_location_alt),
            label: Text(
              _point == null
                  ? _t('fleet.ship.dropoff.set')
                  : [_neighborhood, _city, _province]
                      .whereType<String>()
                      .where((e) => e.trim().isNotEmpty)
                      .join(', ')
                      .ifEmpty(_t('fleet.ship.dropoff.set')),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          TextField(
            controller: _itemDesc,
            enabled: !_saving,
            decoration: InputDecoration(labelText: _t('fleet.ship.item')),
          ),
          const SizedBox(height: AppSpacing.lg),
          TextField(
            controller: _price,
            enabled: !_saving,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: _t('fleet.ship.price'),
              helperText: _t('fleet.ship.price.hint'),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _cod,
            onChanged: _saving ? null : (v) => setState(() => _cod = v),
            title: Text(_t('fleet.ship.cod')),
          ),
          if (_cod)
            TextField(
              controller: _codAmount,
              enabled: !_saving,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: _t('fleet.ship.cod.amount')),
            ),
          const SizedBox(height: AppSpacing.lg),
          DropdownButtonFormField<String?>(
            initialValue: _driverUuid,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: _t('fleet.ship.driver'),
              helperText: _t('fleet.ship.driver.hint'),
            ),
            items: [
              DropdownMenuItem<String?>(
                value: null,
                child: Text(_t('fleet.ship.driver.later')),
              ),
              for (final d in drivers)
                DropdownMenuItem<String?>(
                  value: d['uuid'] as String?,
                  child: Text((d['name'] as String?) ?? '—',
                      overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) => setState(() => _driverUuid = v),
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
                : Text(_t('fleet.ship.submit')),
          ),
        ],
      ),
    );
  }
}

extension _IfEmpty on String {
  String ifEmpty(String fallback) => trim().isEmpty ? fallback : this;
}
