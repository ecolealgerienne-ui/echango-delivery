import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/order_state.dart';

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
      if (mounted) context.read<OrderState>().loadAddresses();
    });
  }

  Future<void> _addAddress(OrderState orderState) async {
    final name = TextEditingController();
    final address = TextEditingController();
    final contact = TextEditingController();
    final phone = TextEditingController();

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Nouvelle adresse'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Nom *'),
              ),
              TextField(
                controller: address,
                decoration: const InputDecoration(labelText: 'Adresse'),
              ),
              TextField(
                controller: contact,
                decoration: const InputDecoration(labelText: 'Contact'),
              ),
              TextField(
                controller: phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Téléphone'),
              ),
              const SizedBox(height: 12),
              const Text(
                'La position précise sera réglable sur une carte dans une '
                'prochaine version. En attendant, l\'adresse est enregistrée '
                'au centre-ville.',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );

    if (saved != true || !mounted) return;
    if (name.text.trim().isEmpty) return;

    final messenger = ScaffoldMessenger.of(context);
    final ok = await orderState.saveAddress(
      label: 'commerce',
      name: name.text.trim(),
      address: address.text.trim(),
      // Repli tant que la sélection sur carte n'existe pas — centre d'Alger.
      latitude: 36.7538,
      longitude: 3.0588,
      contactName: contact.text.trim(),
      contactPhone: phone.text.trim(),
    );
    if (!mounted) return;

    messenger.showSnackBar(
      SnackBar(
        content: Text(ok
            ? 'Adresse enregistrée'
            : orderState.errorMessage ?? 'Enregistrement impossible'),
        backgroundColor: ok ? null : Colors.red,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final orderState = context.watch<OrderState>();

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
