import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:latlong2/latlong.dart';

import '../../state/merchant_order_state.dart';
import 'map_picker_screen.dart';

/// Carnet d'adresses du commerçant.
///
/// Côté Fleetbase ce sont des `Place` rattachés à son Vendor par `owner_uuid`,
/// un filtre serveur réel — vérifié en pratique (journal §2.7), contrairement
/// aux filtres de `/orders` et `/drivers` qui sont ignorés silencieusement.
class AddressesScreen extends StatefulWidget {
  const AddressesScreen({super.key});

  @override
  State<AddressesScreen> createState() => _AddressesScreenState();
}

class _AddressesScreenState extends State<AddressesScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<MerchantOrderState>().loadAddresses();
    });
  }

  /// Ouvre le formulaire d'adresse.
  ///
  /// Une page et non une boîte de dialogue : la position se choisit sur une
  /// carte, et un dialogue ne peut pas en ouvrir une proprement. La version
  /// précédente enregistrait donc **le centre d'Alger pour toute adresse** —
  /// pire encore qu'à la création d'une commande, puisqu'une adresse fausse
  /// empoisonne ensuite chaque livraison qui la réutilise.
  Future<void> _addAddress(MerchantOrderState orderState) async {
    final messenger = ScaffoldMessenger.of(context);

    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const _AddressFormScreen()),
    );

    if (result != true || !mounted) return;
    messenger.showSnackBar(const SnackBar(content: Text('Adresse enregistrée')));
  }

  @override
  Widget build(BuildContext context) {
    final orderState = context.watch<MerchantOrderState>();

    return Scaffold(
      appBar: AppBar(title: const Text('Carnet d\'adresses')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _addAddress(orderState),
        child: const Icon(Icons.add),
      ),
      body: orderState.addresses.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.bookmark_border, size: 64, color: Colors.grey[400]),
                    const SizedBox(height: 16),
                    Text('Aucune adresse enregistrée',
                        style: TextStyle(color: Colors.grey[600], fontSize: 16)),
                    const SizedBox(height: 8),
                    Text(
                      'Enregistrez vos points de retrait et destinataires '
                      'fréquents pour remplir une demande en un tap.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey[500], fontSize: 12),
                    ),
                  ],
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: orderState.addresses.length,
              itemBuilder: (context, index) {
                final a = orderState.addresses[index];
                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  child: ListTile(
                    leading: const Icon(Icons.place_outlined),
                    title: Text(a.name),
                    subtitle: Text(
                      [a.address, a.contactPhone].where((e) => e != null && e.isNotEmpty).join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                );
              },
            ),
    );
  }
}


/// Formulaire d'adresse, position comprise.
class _AddressFormScreen extends StatefulWidget {
  const _AddressFormScreen();

  @override
  State<_AddressFormScreen> createState() => _AddressFormScreenState();
}

class _AddressFormScreenState extends State<_AddressFormScreen> {
  final _name = TextEditingController();
  final _address = TextEditingController();
  final _contact = TextEditingController();
  final _phone = TextEditingController();

  /// Nulle tant que le commerçant n'a pas placé le point. L'enregistrement est
  /// refusé dans ce cas plutôt que d'inventer une position.
  LatLng? _point;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_name, _address, _contact, _phone]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickOnMap() async {
    final result = await Navigator.of(context).push<PickedLocation>(
      MaterialPageRoute(
        builder: (_) => MapPickerScreen(
          title: 'Position de l\'adresse',
          initial: _point,
        ),
      ),
    );
    if (result == null || !mounted) return;

    setState(() {
      _point = result.point;
      if (_address.text.trim().isEmpty) _address.text = result.label;
    });
  }

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final orderState = context.read<MerchantOrderState>();

    if (_name.text.trim().isEmpty || _point == null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(_name.text.trim().isEmpty
              ? 'Le nom est obligatoire'
              : 'Placez la position sur la carte'),
        ),
      );
      return;
    }

    setState(() => _saving = true);
    final ok = await orderState.saveAddress(
      label: 'commerce',
      name: _name.text.trim(),
      address: _address.text.trim(),
      latitude: _point!.latitude,
      longitude: _point!.longitude,
      contactName: _contact.text.trim(),
      contactPhone: _phone.text.trim(),
    );
    if (!mounted) return;
    setState(() => _saving = false);

    if (ok) {
      navigator.pop(true);
    } else {
      messenger.showSnackBar(
        SnackBar(
          content: Text(orderState.errorMessage ?? 'Enregistrement impossible'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nouvelle adresse')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _field(_name, 'Nom *', Icons.label_outline),
              _field(_address, 'Adresse', Icons.place_outlined),
              _field(_contact, 'Contact', Icons.person_outline),
              _field(_phone, 'Téléphone', Icons.phone_outlined,
                  keyboard: TextInputType.phone),
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: _pickOnMap,
                icon: const Icon(Icons.map_outlined),
                label: Text(_point == null
                    ? 'Placer sur la carte *'
                    : 'Modifier la position'),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    _point == null
                        ? Icons.error_outline
                        : Icons.check_circle_outline,
                    size: 16,
                    color: _point == null
                        ? Theme.of(context).colorScheme.error
                        : Colors.green.shade700,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _point == null
                          ? 'Position non définie — c\'est elle qui permet de '
                              'trouver un transporteur à proximité'
                          : 'Position définie',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: const Text('Enregistrer'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label,
    IconData icon, {
    TextInputType? keyboard,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: controller,
          keyboardType: keyboard,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
            prefixIcon: Icon(icon),
            isDense: true,
          ),
        ),
      );
}
