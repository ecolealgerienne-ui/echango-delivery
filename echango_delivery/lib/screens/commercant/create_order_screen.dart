import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../models/merchant_order.dart';
import '../../models/vehicle_type.dart';
import '../../services/bff_api_client.dart';
import '../../state/merchant_order_state.dart';
import 'map_picker_screen.dart';

/// Formulaire de demande de livraison.
///
/// Chaque point se définit de trois façons, par ordre de précision : une
/// adresse du carnet, une recherche d'adresse, ou un point placé sur la carte.
///
/// ⚠️ **Les coordonnées ne sont plus devinées.** La version précédente
/// retombait sur le centre d'Alger dès qu'aucune adresse enregistrée n'était
/// choisie : le dispatch géospatial de Fleetbase travaillait donc sur un point
/// faux, et deux livraisons opposées dans la ville avaient la même position.
/// Le formulaire exige désormais un point réel — c'est la seule donnée du
/// formulaire dont dépend le choix du transporteur.
class CreateOrderScreen extends StatefulWidget {
  const CreateOrderScreen({super.key});

  @override
  State<CreateOrderScreen> createState() => _CreateOrderScreenState();
}

class _CreateOrderScreenState extends State<CreateOrderScreen> {
  final _pickupName = TextEditingController();
  final _pickupAddress = TextEditingController();
  final _pickupContact = TextEditingController();
  final _pickupPhone = TextEditingController();

  final _dropoffName = TextEditingController();
  final _dropoffAddress = TextEditingController();
  final _dropoffContact = TextEditingController();
  final _dropoffPhone = TextEditingController();

  final _instructions = TextEditingController();
  final _itemDescription = TextEditingController();
  final _price = TextEditingController();

  /// Dernier devis renvoyé par le serveur.
  ///
  /// Toute la tarification est **centralisée dans le BFF** : l'app ne calcule
  /// rien, elle affiche. Le jour où le barème existera, `isComputed` deviendra
  /// vrai et l'écran basculera de la saisie manuelle au montant affiché, sans
  /// modification de code ici.
  OrderQuote? _quote;
  bool _quoting = false;

  /// Livraison programmée. `null` = dès que possible.
  DateTime? _scheduledAt;

  /// Catégorie minimale de véhicule. `null` = indifférent.
  String? _vehicleType;

  /// Niveau de preuve exigé. `photo` par défaut : c'est le seul validé de bout
  /// en bout côté transporteur, et une livraison sans trace est ce qui rend un
  /// litige insoluble.
  String _podMethod = 'photo';

  /// Solliciter d'abord les transporteurs favoris.
  bool _preferFavourites = true;

  /// Nulles tant que le commerçant n'a pas désigné de point. Le formulaire
  /// refuse l'envoi dans ce cas plutôt que d'inventer une position.
  LatLng? _pickupPoint;
  LatLng? _dropoffPoint;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = context.read<MerchantOrderState>();
      state.loadAddresses();
      state.loadFavourites();
    });
  }

  @override
  void dispose() {
    for (final c in [
      _pickupName, _pickupAddress, _pickupContact, _pickupPhone,
      _dropoffName, _dropoffAddress, _dropoffContact, _dropoffPhone,
      _instructions, _itemDescription, _price,
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
        _pickupPoint = LatLng(a.latitude, a.longitude);
      } else {
        _dropoffName.text = a.name;
        _dropoffAddress.text = a.address;
        _dropoffContact.text = a.contactName ?? '';
        _dropoffPhone.text = a.contactPhone ?? '';
        _dropoffPoint = LatLng(a.latitude, a.longitude);
      }
    });
  }

  Future<void> _submit(MerchantOrderState orderState) async {
    final missing = <String>[
      if (_pickupName.text.trim().isEmpty) 'le lieu de retrait',
      if (_pickupPhone.text.trim().isEmpty) 'le téléphone de retrait',
      if (_dropoffName.text.trim().isEmpty) 'le nom du destinataire',
      if (_dropoffPhone.text.trim().isEmpty) 'le téléphone du destinataire',
      if (_pickupPoint == null) 'le point de retrait sur la carte',
      if (_dropoffPoint == null) 'le point de livraison sur la carte',
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
      'pickupLatitude': _pickupPoint!.latitude,
      'pickupLongitude': _pickupPoint!.longitude,
      'pickupContactName':
          _pickupContact.text.trim().isEmpty ? 'Commerce' : _pickupContact.text.trim(),
      'pickupContactPhone': _pickupPhone.text.trim(),
      if (_pickupAddress.text.trim().isNotEmpty)
        'pickupNotes': _pickupAddress.text.trim(),
      'dropoffLocationName': _dropoffName.text.trim(),
      'dropoffLatitude': _dropoffPoint!.latitude,
      'dropoffLongitude': _dropoffPoint!.longitude,
      'dropoffContactName':
          _dropoffContact.text.trim().isEmpty ? _dropoffName.text.trim() : _dropoffContact.text.trim(),
      'dropoffContactPhone': _dropoffPhone.text.trim(),
      if (_dropoffAddress.text.trim().isNotEmpty)
        'dropoffNotes': _dropoffAddress.text.trim(),
      if (_instructions.text.trim().isNotEmpty)
        'deliveryInstructions': _instructions.text.trim(),
      if (_scheduledAt != null) 'scheduledAt': _scheduledAt!.toUtc().toIso8601String(),
      if (_vehicleType != null) 'vehicleType': _vehicleType,
      'podMethod': _podMethod,
      'preferFavourites': _preferFavourites,
      if (double.tryParse(_price.text.trim()) != null)
        'price': double.parse(_price.text.trim()),
      if (_itemDescription.text.trim().isNotEmpty)
        'items': [
          {'description': _itemDescription.text.trim(), 'quantity': 1},
        ],
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
                _locationRow(orderState, toPickup: true),
                _field(_pickupName, 'Lieu de retrait *', Icons.storefront_outlined),
                _field(_pickupAddress, 'Adresse', Icons.place_outlined),
                _field(_pickupContact, 'Contact sur place', Icons.person_outline),
                _field(_pickupPhone, 'Téléphone *', Icons.phone_outlined,
                    keyboard: TextInputType.phone),
                const SizedBox(height: 24),
                _section('Livraison'),
                _locationRow(orderState, toPickup: false),
                _field(_dropoffName, 'Destinataire *', Icons.person_outline),
                _field(_dropoffAddress, 'Adresse', Icons.place_outlined),
                _field(_dropoffContact, 'Contact (si différent)', Icons.person_outline),
                _field(_dropoffPhone, 'Téléphone *', Icons.phone_outlined,
                    keyboard: TextInputType.phone),
                const SizedBox(height: 24),
                _section('Colis'),
                _field(_itemDescription, 'Contenu (ex. : gâteau, médicaments)',
                    Icons.inventory_2_outlined),
                _vehicleSelector(),
                _pricingSection(),
                const SizedBox(height: 16),
                _section('Options'),
                _scheduleTile(),
                _podSelector(),
                _favouritesTile(orderState),
                const SizedBox(height: 16),
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

  /// Sélecteur d'adresse et point sur la carte.
  ///
  /// Les puces d'origine listaient tout le carnet à l'écran : lisible avec
  /// deux clients, inutilisable avec trente. Un sélecteur avec recherche tient
  /// à l'échelle, et le bouton carte reste toujours accessible — c'est le seul
  /// moyen de désigner une adresse qui n'est pas encore au carnet.
  Widget _locationRow(MerchantOrderState orderState, {required bool toPickup}) {
    final point = toPickup ? _pickupPoint : _dropoffPoint;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (orderState.addresses.isNotEmpty) ...[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _pickFromAddressBook(orderState, toPickup: toPickup),
                    icon: const Icon(Icons.bookmark_outline, size: 18),
                    label: const Text('Carnet'),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () => _pickOnMap(toPickup: toPickup),
                  icon: const Icon(Icons.map_outlined, size: 18),
                  label: Text(point == null ? 'Placer sur la carte' : 'Modifier le point'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Rendre la position visible : sans ce retour, le commerçant ne sait
          // pas si son point est défini, et c'est pourtant la seule donnée du
          // formulaire dont dépend le choix du transporteur.
          Row(
            children: [
              Icon(
                point == null ? Icons.error_outline : Icons.check_circle_outline,
                size: 16,
                color: point == null
                    ? Theme.of(context).colorScheme.error
                    : Colors.green.shade700,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  point == null
                      ? 'Position non définie'
                      : 'Position définie (${point.latitude.toStringAsFixed(5)}, '
                          '${point.longitude.toStringAsFixed(5)})',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Catégorie de véhicule exigée.
  ///
  /// Formulée comme un minimum et non comme un choix exclusif : demander une
  /// voiture n'écarte pas un utilitaire. Traiter ce champ comme une égalité
  /// stricte priverait la course de transporteurs parfaitement capables.
  Widget _vehicleSelector() {
    const options = {
      null: 'Indifférent',
      'moto': 'Moto minimum',
      'voiture': 'Voiture minimum',
      'utilitaire': 'Utilitaire requis',
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String?>(
        initialValue: _vehicleType,
        decoration: InputDecoration(
          labelText: 'Véhicule nécessaire',
          border: const OutlineInputBorder(),
          // L'icône suit la sélection : figée sur la moto, elle contredisait le
          // libellé et laissait croire que le choix n'avait pas été pris en
          // compte.
          prefixIcon: Icon(vehicleIcon(_vehicleType)),
          isDense: true,
        ),
        items: options.entries
            .map((e) => DropdownMenuItem<String?>(value: e.key, child: Text(e.value)))
            .toList(),
        onChanged: (v) {
          setState(() => _vehicleType = v);
          _refreshQuote();
        },
      ),
    );
  }

  /// Bloc tarification.
  ///
  /// Deux présentations selon ce que renvoie le serveur, et **c'est lui qui
  /// décide** : tant qu'aucun barème n'est implémenté, le commerçant propose
  /// son montant ; dès que la formule existe, le tarif s'affiche et la saisie
  /// disparaît. L'écran n'a pas à connaître la règle, seulement à obéir au
  /// devis.
  Widget _pricingSection() {
    final quote = _quote;
    final theme = Theme.of(context);

    if (quote != null && quote.isComputed) {
      return Card(
        color: theme.colorScheme.secondaryContainer,
        child: ListTile(
          leading: const Icon(Icons.payments_outlined),
          title: Text(quote.formattedAmount!,
              style: theme.textTheme.titleLarge),
          subtitle: Text(
            quote.approximateDistance == null
                ? 'Tarif Echango pour cette course'
                : 'Tarif Echango — ${quote.approximateDistance}',
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _field(_price, 'Rémunération proposée (DZD)', Icons.payments_outlined,
            keyboard: TextInputType.number),
        Row(
          children: [
            if (_quoting)
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: SizedBox(
                  height: 12,
                  width: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            Expanded(
              child: Text(
                quote?.approximateDistance == null
                    ? 'Ce montant est affiché aux transporteurs : c\'est sur lui '
                        'qu\'ils décident de prendre la course.'
                    : 'Distance estimée : ${quote!.approximateDistance}. '
                        'Ce montant est affiché aux transporteurs.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _scheduleTile() {
    final label = _scheduledAt == null
        ? 'Dès que possible'
        : '${_scheduledAt!.day}/${_scheduledAt!.month} à '
            '${_scheduledAt!.hour.toString().padLeft(2, '0')}h'
            '${_scheduledAt!.minute.toString().padLeft(2, '0')}';

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.schedule_outlined),
      title: const Text('Enlèvement'),
      subtitle: Text(label),
      trailing: _scheduledAt == null
          ? const Icon(Icons.chevron_right)
          : IconButton(
              icon: const Icon(Icons.clear),
              tooltip: 'Revenir à « dès que possible »',
              onPressed: () => setState(() => _scheduledAt = null),
            ),
      onTap: _pickSchedule,
    );
  }

  Future<void> _pickSchedule() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _scheduledAt ?? now,
      firstDate: now,
      // Deux semaines : au-delà, une livraison programmée relève de la
      // planification, pas de ce formulaire.
      lastDate: now.add(const Duration(days: 14)),
    );
    if (date == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_scheduledAt ?? now),
    );
    if (time == null || !mounted) return;

    setState(() {
      _scheduledAt =
          DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
    _refreshQuote();
  }

  /// Niveau de preuve exigé à la livraison.
  ///
  /// `signature` n'est pas proposé : le contrat serveur l'accepte, mais rien
  /// ne le recueille côté transporteur. L'offrir promettrait une trace qui
  /// n'existerait pas — pire qu'une option absente.
  Widget _podSelector() {
    const options = {
      'photo': 'Photo à la livraison',
      'aucune': 'Aucune preuve',
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: DropdownButtonFormField<String>(
        initialValue: _podMethod,
        decoration: const InputDecoration(
          labelText: 'Preuve de livraison',
          border: OutlineInputBorder(),
          prefixIcon: Icon(Icons.verified_outlined),
          isDense: true,
        ),
        items: options.entries
            .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
            .toList(),
        onChanged: (v) => setState(() => _podMethod = v ?? 'photo'),
      ),
    );
  }

  /// Préférence pour les transporteurs favoris.
  ///
  /// Le libellé dit explicitement le repli : sans lui, le commerçant croirait
  /// que cocher la case bloque sa course quand ses favoris sont occupés.
  Widget _favouritesTile(MerchantOrderState orderState) {
    if (orderState.favourites.isEmpty) return const SizedBox.shrink();

    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      value: _preferFavourites,
      onChanged: (v) => setState(() => _preferFavourites = v),
      title: const Text('Proposer d\'abord à mes transporteurs habituels'),
      subtitle: Text(
        '${orderState.favourites.length} favori(s). Si aucun n\'est disponible, '
        'la course est proposée à l\'ensemble du réseau.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }

  Future<void> _pickFromAddressBook(
    MerchantOrderState orderState, {
    required bool toPickup,
  }) async {
    final chosen = await showModalBottomSheet<SavedAddress>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _AddressBookSheet(addresses: orderState.addresses),
    );
    if (chosen != null) _applyAddress(chosen, toPickup: toPickup);
  }

  Future<void> _pickOnMap({required bool toPickup}) async {
    final result = await Navigator.of(context).push<PickedLocation>(
      MaterialPageRoute(
        builder: (_) => MapPickerScreen(
          title: toPickup ? 'Point de retrait' : 'Point de livraison',
          initial: toPickup ? _pickupPoint : _dropoffPoint,
        ),
      ),
    );
    if (result == null || !mounted) return;

    setState(() {
      if (toPickup) {
        _pickupPoint = result.point;
        if (_pickupAddress.text.trim().isEmpty) _pickupAddress.text = result.label;
      } else {
        _dropoffPoint = result.point;
        if (_dropoffAddress.text.trim().isEmpty) _dropoffAddress.text = result.label;
      }
    });
    _refreshQuote();
  }

  /// Demande un devis au serveur.
  ///
  /// Appelé dès que les deux points sont connus, puis à chaque changement d'un
  /// paramètre tarifaire — horaire, véhicule. Sans les deux points, il n'y a
  /// pas de distance, donc rien à calculer.
  Future<void> _refreshQuote() async {
    final pickup = _pickupPoint;
    final dropoff = _dropoffPoint;
    if (pickup == null || dropoff == null) return;

    final api = context.read<BffApiClient>();
    setState(() => _quoting = true);
    try {
      final quote = await api.quoteOrder(
        pickupLatitude: pickup.latitude,
        pickupLongitude: pickup.longitude,
        dropoffLatitude: dropoff.latitude,
        dropoffLongitude: dropoff.longitude,
        scheduledAt: _scheduledAt?.toUtc().toIso8601String(),
        vehicleType: _vehicleType,
      );
      if (mounted) setState(() => _quote = quote);
    } catch (_) {
      // Un devis indisponible ne doit pas empêcher de commander : la saisie
      // manuelle reste le mode nominal tant qu'aucun barème n'existe.
      if (mounted) setState(() => _quote = null);
    } finally {
      if (mounted) setState(() => _quoting = false);
    }
  }
}

/// Carnet d'adresses avec recherche.
///
/// Une feuille plutôt qu'un `DropdownButton` : au-delà d'une dizaine d'entrées
/// un menu déroulant devient pénible sur mobile, et il n'accueille pas de champ
/// de recherche.
class _AddressBookSheet extends StatefulWidget {
  final List<SavedAddress> addresses;

  const _AddressBookSheet({required this.addresses});

  @override
  State<_AddressBookSheet> createState() => _AddressBookSheetState();
}

class _AddressBookSheetState extends State<_AddressBookSheet> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final needle = _filter.trim().toLowerCase();
    final visible = needle.isEmpty
        ? widget.addresses
        : widget.addresses
            .where((a) =>
                a.name.toLowerCase().contains(needle) ||
                a.address.toLowerCase().contains(needle))
            .toList();

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            autofocus: true,
            onChanged: (v) => setState(() => _filter = v),
            decoration: const InputDecoration(
              hintText: 'Rechercher dans le carnet…',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.5,
            ),
            child: visible.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Text('Aucune adresse ne correspond'),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: visible.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final a = visible[i];
                      return ListTile(
                        leading: const Icon(Icons.bookmark_outline),
                        title: Text(a.name),
                        subtitle: Text(
                          a.address,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => Navigator.pop(context, a),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
