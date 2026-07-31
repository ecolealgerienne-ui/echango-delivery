import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../models/merchant_order.dart';
import '../../models/vehicle_type.dart';
import '../../services/bff_api_client.dart';
import '../../state/merchant_order_state.dart';
import 'map_picker_screen.dart';
import '../../config/app_rules.dart';
import '../../theme/app_spacing.dart';

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
  /// Champs repris d'une livraison passée, tels que renvoyés par
  /// `GET /commercant/commandes/:id/modele`.
  ///
  /// Volontairement une `Map` brute et non un modèle typé : sa forme est
  /// exactement celle du corps de création, et un modèle intermédiaire
  /// n'ajouterait qu'un endroit de plus où oublier un champ quand le
  /// formulaire s'enrichira.
  ///
  /// L'enlèvement programmé n'y figure jamais : celui de la commande d'origine
  /// est dans le passé, et le formulaire retombe sur « dès que possible ».
  final Map<String, dynamic>? template;

  const CreateOrderScreen({super.key, this.template});

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
  final _itemWeight = TextEditingController();
  final _price = TextEditingController();
  final _codAmount = TextEditingController();

  /// Le destinataire paie-t-il à la réception ?
  ///
  /// Séparé du montant pour que décocher n'efface pas la saisie : un commerçant
  /// qui hésite ne doit pas retaper.
  bool _cashOnDelivery = false;

  /// Le montant à encaisser couvre-t-il aussi les frais de livraison ?
  ///
  /// Vrai par défaut : c'est l'usage courant — le client règle tout en une
  /// fois. Purement informatif pour le règlement, qui est le même dans les deux
  /// cas, mais il change ce que le commerçant doit saisir comme montant.
  bool _codIncludesDelivery = true;

  /// Contenu imposant des précautions de transport. Le contrat serveur
  /// l'accepte depuis l'origine ; le formulaire ne l'envoyait pas.
  bool _fragile = false;

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
    _applyTemplate();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final state = context.read<MerchantOrderState>();
      await state.loadAddresses();
      state.loadFavourites();
      if (!mounted) return;

      // Préremplit le retrait avec l'adresse principale (décision produit,
      // 30/07/2026) — seulement à la création d'une nouvelle livraison :
      // dupliquer une commande passée a déjà son propre point de retrait, et
      // l'écraser romprait avec le principe même de « refaire cette
      // livraison ».
      if (widget.template == null && _pickupPoint == null) {
        SavedAddress? defaultAddress;
        for (final a in state.addresses) {
          if (a.isDefault) {
            defaultAddress = a;
            break;
          }
        }
        if (defaultAddress != null) _applyAddress(defaultAddress, toPickup: true);
      }

      // Le devis est demandé d'emblée sur une commande reprise : les deux
      // points sont déjà connus, et attendre une modification pour l'afficher
      // laisserait le champ prix vide alors que tout est là.
      if (_pickupPoint != null && _dropoffPoint != null) _refreshQuote();
    });
  }

  /// Reprend les champs d'une livraison passée.
  ///
  /// Appliqué dans `initState` et non dans un `postFrameCallback` : les
  /// contrôleurs de texte doivent porter leur valeur avant la première
  /// construction, sinon l'écran s'affiche vide puis se remplit — ce qui se lit
  /// comme un formulaire qui s'auto-modifie.
  ///
  /// Tolérant sur les types : un champ absent ou d'un type inattendu est
  /// ignoré, il laisse simplement sa case à remplir. Une duplication qui
  /// planterait sur un champ manquant serait pire que pas de duplication.
  void _applyTemplate() {
    final t = widget.template;
    if (t == null) return;

    String text(String key) {
      final value = t[key];
      return value is String ? value : '';
    }

    double? coord(String key) {
      final value = t[key];
      return value is num ? value.toDouble() : null;
    }

    _pickupName.text = text('pickupLocationName');
    _pickupAddress.text = text('pickupNotes');
    _pickupContact.text = text('pickupContactName');
    _pickupPhone.text = text('pickupContactPhone');

    _dropoffName.text = text('dropoffLocationName');
    _dropoffAddress.text = text('dropoffNotes');
    _dropoffContact.text = text('dropoffContactName');
    _dropoffPhone.text = text('dropoffContactPhone');

    _instructions.text = text('deliveryInstructions');

    final items = t['items'];
    if (items is List && items.isNotEmpty && items.first is Map) {
      final item = items.first as Map;
      final description = item['description'];
      if (description is String) _itemDescription.text = description;
      final weight = item['weight'];
      if (weight is num) _itemWeight.text = weight.toString();
      _fragile = item['fragile'] == true;
    }

    final price = t['price'];
    if (price is num) _price.text = price.toStringAsFixed(0);

    final cod = t['codAmount'];
    if (cod is num) {
      _codAmount.text = cod.toStringAsFixed(0);
      _cashOnDelivery = true;
      _codIncludesDelivery = t['codIncludesDelivery'] == true;
    }

    final vehicle = t['vehicleType'];
    if (vehicle is String) _vehicleType = vehicle;

    final pod = t['podMethod'];
    if (pod is String) _podMethod = pod;

    final preferFav = t['preferFavourites'];
    if (preferFav is bool) _preferFavourites = preferFav;

    final pickupLat = coord('pickupLatitude');
    final pickupLon = coord('pickupLongitude');
    if (pickupLat != null && pickupLon != null) {
      _pickupPoint = LatLng(pickupLat, pickupLon);
    }

    final dropoffLat = coord('dropoffLatitude');
    final dropoffLon = coord('dropoffLongitude');
    if (dropoffLat != null && dropoffLon != null) {
      _dropoffPoint = LatLng(dropoffLat, dropoffLon);
    }
  }

  @override
  void dispose() {
    for (final c in [
      _pickupName, _pickupAddress, _pickupContact, _pickupPhone,
      _dropoffName, _dropoffAddress, _dropoffContact, _dropoffPhone,
      _instructions, _itemDescription, _itemWeight, _price, _codAmount,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Applique une adresse du carnet au formulaire.
  ///
  /// ⚠️ La position n'est plus garantie : une adresse peut être enregistrée
  /// sans elle (décision produit, 30/07/2026). Reconduire `(0, 0)` comme un
  /// point valide referait exactement l'erreur déjà corrigée pour la carte —
  /// une commande dispatchée depuis le golfe de Guinée. Le point reste donc
  /// `null`, et le bandeau de statut en dessous du bouton carte le signale.
  void _applyAddress(SavedAddress a, {required bool toPickup}) {
    setState(() {
      // `street1` et non `address` : l'accesseur de Fleetbase recompose le nom
      // du lieu avec sa rue, donc reprendre `address` remplissait le champ
      // « Adresse » avec le nom déjà présent juste au-dessus — la fiche de
      // livraison affichait trois fois « BOULANGERIE TEST ».
      if (toPickup) {
        _pickupName.text = a.name;
        _pickupAddress.text = a.street1;
        _pickupContact.text = a.contactName ?? '';
        _pickupPhone.text = a.contactPhone ?? '';
        _pickupPoint = a.hasPosition ? LatLng(a.latitude, a.longitude) : null;
      } else {
        _dropoffName.text = a.name;
        _dropoffAddress.text = a.street1;
        _dropoffContact.text = a.contactName ?? '';
        _dropoffPhone.text = a.contactPhone ?? '';
        _dropoffPoint = a.hasPosition ? LatLng(a.latitude, a.longitude) : null;
      }
    });

    if (!a.hasPosition && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '« ${a.name} » n\'a pas de position enregistrée : placez-la sur '
            'la carte pour continuer.',
          ),
        ),
      );
    }
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

    final orderId = await orderState.createOrder({
      // Toute commande créée depuis ce formulaire naît en brouillon (décision
      // produit, 30/07/2026) : personne n'est sollicité tant que le
      // commerçant n'a pas relu la fiche et cliqué « Publier ». Le dispatch
      // (favori ou pool) est décidé au moment de la publication, pas ici.
      'draft': true,
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
      // Montant à encaisser, distinct de la rémunération du transporteur : le
      // premier va du destinataire au commerçant, le second du commerçant au
      // transporteur. Sens inverses.
      if (_cashOnDelivery && double.tryParse(_codAmount.text.trim()) != null) ...{
        'codAmount': double.parse(_codAmount.text.trim()),
        'codIncludesDelivery': _codIncludesDelivery,
      },
      // Poids et fragilité sont transmis : le contrat serveur les acceptait
      // déjà, le formulaire n'envoyait qu'une description et `quantity: 1` en
      // dur. Or c'est précisément ce qui permet au transporteur de juger si sa
      // moto suffit — donc ce qui fonde son refus pour `colis_inadapte`.
      if (_itemDescription.text.trim().isNotEmpty)
        'items': [
          {
            'description': _itemDescription.text.trim(),
            'quantity': 1,
            if (double.tryParse(_itemWeight.text.trim()) != null)
              'weight': double.parse(_itemWeight.text.trim()),
            if (_fragile) 'fragile': true,
          },
        ],
    });

    if (!mounted) return;
    if (orderId != null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Brouillon enregistré. Relisez-le puis publiez-le pour trouver un '
            'transporteur.',
          ),
        ),
      );
      // Vers la fiche, pas la liste : le « Publier » y est à portée de main,
      // et c'est le geste qui manque encore pour que la livraison parte
      // réellement.
      router.pushReplacement('/commercant/commandes/$orderId');
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
      // Le titre dit d'où vient le formulaire. Sans ça, un écran pré-rempli
      // ressemble à une commande déjà créée qu'on serait en train de modifier
      // — et le commerçant hésite à valider.
      appBar: AppBar(
        title: Text(
          widget.template == null ? 'Nouvelle livraison' : 'Reprendre une livraison',
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
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
                const SizedBox(height: AppSpacing.xl),
                _section('Livraison'),
                _locationRow(orderState, toPickup: false),
                _field(_dropoffName, 'Destinataire *', Icons.person_outline),
                _field(_dropoffAddress, 'Adresse', Icons.place_outlined),
                _field(_dropoffContact, 'Contact (si différent)', Icons.person_outline),
                _field(_dropoffPhone, 'Téléphone *', Icons.phone_outlined,
                    keyboard: TextInputType.phone),
                const SizedBox(height: AppSpacing.xl),
                _section('Colis'),
                _field(_itemDescription, 'Contenu (ex. : gâteau, médicaments)',
                    Icons.inventory_2_outlined),
                _field(_itemWeight, 'Poids approximatif (kg)',
                    Icons.scale_outlined, keyboard: TextInputType.number),
                // Case à cocher plutôt qu'une consigne écrite : une mention
                // « fragile » noyée dans les instructions se lit après le
                // chargement, quand il est trop tard.
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _fragile,
                  onChanged: (v) => setState(() => _fragile = v ?? false),
                  title: const Text('Contenu fragile'),
                  subtitle: Text(
                    'Signalé au transporteur avant qu\'il accepte la course.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                _vehicleSelector(),
                _pricingSection(),
                const SizedBox(height: AppSpacing.lg),
                _section('Options'),
                _codSection(),
                _scheduleTile(),
                _podSelector(),
                _favouritesTile(orderState),
                const SizedBox(height: AppSpacing.lg),
                _field(_instructions, 'Instructions pour le transporteur',
                    Icons.notes_outlined, maxLines: 3),
                const SizedBox(height: AppSpacing.lg),
                // Dire ce qui se passe ensuite : sans ça, un brouillon qui
                // n'atteint personne tant qu'il n'est pas publié passe pour un
                // dysfonctionnement.
                Container(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: const Text(
                    'Cette livraison est enregistrée en brouillon : aucun '
                    'transporteur n\'est sollicité tant que vous ne l\'avez pas '
                    'publiée depuis sa fiche.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),
                ElevatedButton.icon(
                  onPressed: orderState.isLoading ? null : () => _submit(orderState),
                  icon: orderState.isLoading
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: const Text('Enregistrer en brouillon'),
                ),
                const SizedBox(height: AppSpacing.xxl),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      );

  Widget _field(
    TextEditingController controller,
    String label,
    IconData icon, {
    TextInputType? keyboard,
    int maxLines = 1,
    ValueChanged<String>? onChanged,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.md),
        child: TextField(
          controller: controller,
          keyboardType: keyboard,
          maxLines: maxLines,
          onChanged: onChanged,
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
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
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
                const SizedBox(width: AppSpacing.sm),
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
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
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
        // `onChanged` : la rémunération entre dans le montant réclamé à la
        // porte quand la livraison n'est pas comprise dans le prix de la
        // marchandise. Sans reconstruction, l'aperçu plus bas afficherait un
        // total périmé — le seul endroit où le commerçant peut vérifier
        // l'addition avant de l'imposer à son client.
        _field(_price, 'Rémunération proposée (DZD)', Icons.payments_outlined,
            keyboard: TextInputType.number,
            onChanged: (_) => setState(() {})),
        Row(
          children: [
            if (_quoting)
              const Padding(
                padding: EdgeInsets.only(right: AppSpacing.sm),
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

  /// Paiement à la livraison.
  ///
  /// ── Ce que l'écran doit dire, et qu'il serait tentant de taire ─────────────
  ///
  /// Echango ne détient jamais cet argent : le transporteur l'encaisse, le
  /// conserve, et le remet au commerçant au prochain enlèvement. Un commerçant
  /// qui croirait la plateforme dépositaire prendrait un risque qu'il n'a pas
  /// choisi — c'est exactement le malentendu qui rendait une implémentation
  /// partielle plus dangereuse que l'absence de la fonctionnalité.
  ///
  /// Tous les transporteurs du réseau peuvent prendre une course encaissée :
  /// ils sont sélectionnés et provisionnés par Echango, le contrôle a lieu à
  /// l'entrée du réseau et non commerçant par commerçant.
  /// L'addition, montrée avant qu'elle soit réclamée à quelqu'un.
  ///
  /// Quand la livraison n'est pas comprise dans le prix de la marchandise,
  /// c'est le serveur qui additionne — et le commerçant ne verrait le total
  /// qu'après coup, sur la fiche, alors que le transporteur est déjà parti
  /// avec la consigne d'encaisser ce montant. Le montrer ici est le seul
  /// moment où il peut encore le corriger.
  ///
  /// Rien n'est affiché tant que l'addition n'a pas de sens (marchandise
  /// vide, rémunération inconnue) : un total incomplet serait plus trompeur
  /// que pas de total du tout. Le cas « rémunération manquante » est signalé
  /// séparément, parce que le serveur refusera la création.
  Widget _codTotalPreview(ThemeData theme) {
    final goods = double.tryParse(_codAmount.text.trim());
    if (goods == null || goods <= 0) return const SizedBox.shrink();

    if (_codIncludesDelivery) {
      return Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.xs),
        child: Text(
          'Le destinataire remettra ${goods.toStringAsFixed(0)} DZD.',
          style: theme.textTheme.bodySmall,
        ),
      );
    }

    final fee = double.tryParse(_price.text.trim());
    if (fee == null || fee <= 0) {
      return Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.xs),
        child: Text(
          'Indiquez la rémunération du transporteur : elle sera réclamée au '
          'destinataire en plus de la marchandise.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.error),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Text(
        'Le destinataire remettra ${(goods + fee).toStringAsFixed(0)} DZD '
        '(${goods.toStringAsFixed(0)} de marchandise + '
        '${fee.toStringAsFixed(0)} de livraison).',
        style: theme.textTheme.bodySmall
            ?.copyWith(fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _codSection() {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _cashOnDelivery,
          onChanged: (v) => setState(() => _cashOnDelivery = v),
          title: const Text('Le client paie à la livraison'),
          subtitle: Text(
            'Le transporteur encaisse et vous remet la somme lors de son '
            'prochain passage. Echango ne détient jamais cet argent.',
            style: theme.textTheme.bodySmall,
          ),
        ),
        if (_cashOnDelivery) ...[
          // L'intitulé suit la case ci-dessous, et ce n'est pas cosmétique :
          // « Montant à encaisser » et « Prix de la marchandise » ne
          // désignent le même nombre que lorsque la livraison est comprise
          // dedans. Un intitulé fixe aurait laissé le commerçant saisir un
          // total là où le serveur attend la marchandise seule — l'écart se
          // serait vu à la porte, en espèces.
          _field(
            _codAmount,
            _codIncludesDelivery
                ? 'Montant à encaisser (DZD)'
                : 'Prix de la marchandise (DZD)',
            Icons.account_balance_wallet_outlined,
            keyboard: TextInputType.number,
            onChanged: (_) => setState(() {}),
          ),
          // Ce choix ne change pas le règlement — le transporteur retient sa
          // rémunération dans les deux cas — mais il change **qui paie la
          // livraison**, donc le montant réclamé à la porte. D'où sa place
          // ici, et non dans un écran de réglages.
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _codIncludesDelivery,
            onChanged: (v) => setState(() => _codIncludesDelivery = v ?? true),
            title: const Text('Les frais de livraison sont inclus'),
            subtitle: Text(
              _codIncludesDelivery
                  ? 'Le client règle la marchandise et la livraison en une fois.'
                  : 'Les frais de livraison sont réclamés au client en plus '
                      'de la marchandise.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          _codTotalPreview(theme),
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: Text(
              'Le transporteur retient sa rémunération sur les espèces et ne '
              'vous remet que la différence, lors de son prochain passage.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
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
      // Décision d'interface, pas règle métier : `CreateOrderDto.scheduledAt`
      // n'est qu'un `@IsISO8601()` côté serveur, qui accepterait une date à
      // deux ans.
      lastDate: now.add(AppRules.schedulingHorizon),
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
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
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
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        top: AppSpacing.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.lg,
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
          const SizedBox(height: AppSpacing.md),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.5,
            ),
            child: visible.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.xxl),
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
