import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/merchant_order.dart';
import '../../state/merchant_order_state.dart';

/// Formulaire de demande de livraison.
///
/// Saisie en texte, avec réutilisation du carnet d'adresses (décision produit
/// du 28/07 : la sélection sur carte viendra plus tard). Les coordonnées ne
/// sont donc pas issues d'un géocodage : elles proviennent soit d'une adresse
/// enregistrée, soit d'une valeur par défaut, ce qui suffit à un dispatch
/// géospatial approximatif mais devra être repris avec la carte.
class CreateOrderScreen extends StatefulWidget {
  const CreateOrderScreen({super.key});

  @override
  State<CreateOrderScreen> createState() => _CreateOrderScreenState();
}

class _CreateOrderScreenState extends State<CreateOrderScreen> {
  // Centre d'Alger — repli tant qu'aucune coordonnée précise n'est disponible.
  static const _defaultLat = 36.7538;
  static const _defaultLng = 3.0588;

  final _pickupName = TextEditingController();
  final _pickupAddress = TextEditingController();
  final _pickupContact = TextEditingController();
  final _pickupPhone = TextEditingController();

  final _dropoffName = TextEditingController();
  final _dropoffAddress = TextEditingController();
  final _dropoffContact = TextEditingController();
  final _dropoffPhone = TextEditingController();

  final _instructions = TextEditingController();

  double _pickupLat = _defaultLat;
  double _pickupLng = _defaultLng;
  double _dropoffLat = _defaultLat;
  double _dropoffLng = _defaultLng;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<MerchantOrderState>().loadAddresses();
    });
  }

  @override
  void dispose() {
    for (final c in [
      _pickupName, _pickupAddress, _pickupContact, _pickupPhone,
      _dropoffName, _dropoffAddress, _dropoffContact, _dropoffPhone,
      _instructions,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _applyAddress(SavedAddress a, {required bool toPickup}) {
    setState(() {
      if (toPickup) {
        _pickupName.text = a.name;
        _pickupAddress.text = a.address;
        _pickupContact.text = a.contactName ?? '';
        _pickupPhone.text = a.contactPhone ?? '';
        _pickupLat = a.latitude;
        _pickupLng = a.longitude;
      } else {
        _dropoffName.text = a.name;
        _dropoffAddress.text = a.address;
        _dropoffContact.text = a.contactName ?? '';
        _dropoffPhone.text = a.contactPhone ?? '';
        _dropoffLat = a.latitude;
        _dropoffLng = a.longitude;
      }
    });
  }

  Future<void> _submit(MerchantOrderState orderState) async {
    final missing = <String>[
      if (_pickupName.text.trim().isEmpty) 'le lieu de retrait',
      if (_pickupPhone.text.trim().isEmpty) 'le téléphone de retrait',
      if (_dropoffName.text.trim().isEmpty) 'le nom du destinataire',
      if (_dropoffPhone.text.trim().isEmpty) 'le téléphone du destinataire',
    ];
    if (missing.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Il manque ${missing.join(', ')}')),
      );
      return;
    }

    final router = GoRouter.of(context);
    final messenger = ScaffoldMessenger.of(context);

    final success = await orderState.createOrder({
      'pickupLocationName': _pickupName.text.trim(),
      'pickupLatitude': _pickupLat,
      'pickupLongitude': _pickupLng,
      'pickupContactName':
          _pickupContact.text.trim().isEmpty ? 'Commerce' : _pickupContact.text.trim(),
      'pickupContactPhone': _pickupPhone.text.trim(),
      if (_pickupAddress.text.trim().isNotEmpty)
        'pickupNotes': _pickupAddress.text.trim(),
      'dropoffLocationName': _dropoffName.text.trim(),
      'dropoffLatitude': _dropoffLat,
      'dropoffLongitude': _dropoffLng,
      'dropoffContactName':
          _dropoffContact.text.trim().isEmpty ? _dropoffName.text.trim() : _dropoffContact.text.trim(),
      'dropoffContactPhone': _dropoffPhone.text.trim(),
      if (_dropoffAddress.text.trim().isNotEmpty)
        'dropoffNotes': _dropoffAddress.text.trim(),
      if (_instructions.text.trim().isNotEmpty)
        'deliveryInstructions': _instructions.text.trim(),
    });

    if (!mounted) return;
    if (success) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Demande de livraison envoyée')),
      );
      router.pop();
    } else {
      messenger.showSnackBar(
        SnackBar(
          content: Text(orderState.errorMessage ?? 'Création impossible'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final orderState = context.watch<MerchantOrderState>();

    return Scaffold(
      appBar: AppBar(title: const Text('Nouvelle livraison')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _section('Retrait'),
                _addressShortcuts(orderState, toPickup: true),
                _field(_pickupName, 'Lieu de retrait *', Icons.storefront_outlined),
                _field(_pickupAddress, 'Adresse', Icons.place_outlined),
                _field(_pickupContact, 'Contact sur place', Icons.person_outline),
                _field(_pickupPhone, 'Téléphone *', Icons.phone_outlined,
                    keyboard: TextInputType.phone),
                const SizedBox(height: 24),
                _section('Livraison'),
                _addressShortcuts(orderState, toPickup: false),
                _field(_dropoffName, 'Destinataire *', Icons.person_outline),
                _field(_dropoffAddress, 'Adresse', Icons.place_outlined),
                _field(_dropoffContact, 'Contact (si différent)', Icons.person_outline),
                _field(_dropoffPhone, 'Téléphone *', Icons.phone_outlined,
                    keyboard: TextInputType.phone),
                const SizedBox(height: 24),
                _field(_instructions, 'Instructions pour le transporteur',
                    Icons.notes_outlined, maxLines: 3),
                const SizedBox(height: 16),
                // Dire ce qui se passe ensuite : sans ça, une commande qui
                // n'apparaît pas immédiatement côté transporteur passe pour
                // un dysfonctionnement.
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'Votre demande est transmise à Echango, qui recherche un '
                    'transporteur disponible. Vous suivrez son avancement '
                    'depuis la liste des livraisons.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: orderState.isLoading ? null : () => _submit(orderState),
                  icon: orderState.isLoading
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                  label: const Text('Demander un transporteur'),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      );

  Widget _field(
    TextEditingController controller,
    String label,
    IconData icon, {
    TextInputType? keyboard,
    int maxLines = 1,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: controller,
          keyboardType: keyboard,
          maxLines: maxLines,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
            prefixIcon: Icon(icon),
            isDense: true,
          ),
        ),
      );

  /// Remplissage en un tap depuis le carnet. C'est ce qui rend la saisie
  /// texte acceptable en attendant la carte : les coordonnées enregistrées
  /// sont réutilisées telles quelles.
  Widget _addressShortcuts(MerchantOrderState orderState, {required bool toPickup}) {
    if (orderState.addresses.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: orderState.addresses
            .map((a) => ActionChip(
                  avatar: const Icon(Icons.bookmark_outline, size: 16),
                  label: Text(a.name),
                  onPressed: () => _applyAddress(a, toPickup: toPickup),
                ))
            .toList(),
      ),
    );
  }
}
