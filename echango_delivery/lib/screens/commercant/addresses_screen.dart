import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:latlong2/latlong.dart';

import '../../models/merchant_order.dart';
import '../../state/merchant_order_state.dart';
import 'map_picker_screen.dart';
import '../../theme/app_semantic_colors.dart';
import '../../theme/app_spacing.dart';
import '../../widgets/app_snack_bar.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/empty_state.dart';

/// Carnet d'adresses du commerçant.
///
/// Côté Fleetbase ce sont des `Place` rattachés à son Vendor par `owner_uuid`,
/// un filtre serveur réel — vérifié en pratique (journal §2.7).
///
/// ⚠️ La phrase qui suivait ici — « contrairement aux filtres de `/orders` et
/// `/drivers`, ignorés silencieusement » — est **fausse depuis le 29/07/2026**.
/// Fleetbase filtre bien côté serveur ; nous envoyions des noms de paramètre
/// qui n'existent pas (`facilitator_uuid` au lieu de `facilitator`), et il
/// abandonne un paramètre inconnu sans erreur. Voir
/// `docs/architecture_bff_fleetbase.md`.
class AddressesScreen extends StatefulWidget {
  const AddressesScreen({super.key});

  @override
  State<AddressesScreen> createState() => _AddressesScreenState();
}

class _AddressesScreenState extends State<AddressesScreen> {
  /// ⚠️ Le carnet part vide, et l'écran s'ouvre **avant** la lecture. Sans ce
  /// drapeau il affirmait « aucune adresse enregistrée » pendant tout
  /// l'aller-retour, à un commerçant qui en a dix — une phrase fausse au
  /// moment précis où elle est lue.
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await context.read<MerchantOrderState>().loadAddresses();
      if (mounted) setState(() => _loading = false);
    });
  }

  /// Ouvre le formulaire d'adresse.
  ///
  /// Une page et non une boîte de dialogue : la position se choisit sur une
  /// carte, et un dialogue ne peut pas en ouvrir une proprement. La version
  /// précédente enregistrait donc **le centre d'Alger pour toute adresse** —
  /// pire encore qu'à la création d'une commande, puisqu'une adresse fausse
  /// empoisonne ensuite chaque livraison qui la réutilise.
  Future<void> _openForm(SavedAddress? existing) async {

    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => _AddressFormScreen(existing: existing)),
    );

    if (result != true || !mounted) return;
    showAppSnackBar(
      context,
      existing == null ? 'Adresse enregistrée' : 'Adresse modifiée',
    );
  }

  /// Supprime une adresse, après confirmation.
  ///
  /// La confirmation reste légère à dessein : supprimer une entrée du carnet
  /// **n'efface aucun historique**. Chaque livraison a créé son propre lieu à
  /// la commande, distinct de l'entrée du carnet — les livraisons passées
  /// gardent donc leur adresse.
  Future<void> _delete(MerchantOrderState orderState, SavedAddress a) async {
    final confirmed = await AppConfirmDialog.destructive(
      context,
      title: 'Supprimer « ${a.name} » ?',
      message: 'Elle disparaîtra du carnet. Vos livraisons passées ne sont pas '
          'affectées.',
      cancelLabel: 'Retour',
      confirmLabel: 'Supprimer',
    );

    if (!confirmed || !mounted) return;

    final ok = await orderState.deleteAddress(a.id);
    if (!mounted) return;

    showAppOutcome(
      context,
      ok ? null : orderState.errorMessage ?? 'Suppression impossible',
      'Adresse supprimée',
    );
  }

  @override
  Widget build(BuildContext context) {
    final orderState = context.watch<MerchantOrderState>();

    return Scaffold(
      appBar: AppBar(title: const Text('Carnet d\'adresses')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openForm(null),
        child: const Icon(Icons.add),
      ),
      body: _body(orderState),
    );
  }

  /// ⚠️ **Trois états et non deux.** `loadAddresses` avale son erreur pour ne
  /// pas faire remonter d'exception nue, et laisse donc le carnet vide. Une
  /// liste vide peut alors vouloir dire « je n'ai pas pu lire » — et l'annoncer
  /// « aucune adresse enregistrée » est faux, **définitif** (rien ne recharge
  /// ensuite), et pousse le commerçant à ressaisir ce qu'il a déjà.
  Widget _body(MerchantOrderState orderState) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (orderState.addressesUnavailable) {
      return AppEmptyState.unavailable(
        title: 'Carnet d\'adresses indisponible',
        hint: 'Vos adresses n\'ont pas pu être lues. Vérifiez votre connexion, '
            'puis réessayez.',
        scrollable: false,
        onRetry: () => orderState.loadAddresses(),
      );
    }

    if (orderState.addresses.isEmpty) {
      return const AppEmptyState(
        title: 'Aucune adresse enregistrée',
        hint: 'Enregistrez vos points de retrait et destinataires '
            'fréquents pour remplir une demande en un tap.',
        icon: Icons.bookmark_border,
        scrollable: false,
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(AppSpacing.sm),
      itemCount: orderState.addresses.length,
      itemBuilder: (context, index) {
        final a = orderState.addresses[index];
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 6),
          child: ListTile(
            leading: Icon(
              a.isDefault ? Icons.star : Icons.place_outlined,
              color: a.isDefault ? context.semantic.warning : null,
            ),
            title: Row(
              children: [
                Flexible(child: Text(a.name)),
                if (a.isDefault) ...[
                  const SizedBox(width: 6),
                  Text(
                    '· Principale',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: context.semantic.warning),
                  ),
                ],
              ],
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  [a.composedAddress, a.contactName, a.contactPhone]
                      .where((e) => e != null && e.isNotEmpty)
                      .join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                // Une adresse sans position ne peut pas servir : le
                // formulaire de commande exige un point. Le dire ici
                // évite de le découvrir au moment de commander.
                if (!a.hasPosition)
                  Text(
                    'Position manquante — à compléter',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
            // Toute la ligne ouvre la fiche : c'est le geste attendu, et
            // la liste n'était jusqu'ici qu'un affichage mort.
            onTap: () => _openForm(a),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Supprimer',
              onPressed: () => _delete(orderState, a),
            ),
          ),
        );
      },
    );
  }
}


/// Formulaire d'adresse, position comprise.
class _AddressFormScreen extends StatefulWidget {
  /// Adresse à modifier, ou `null` pour une création.
  ///
  /// Le même formulaire sert aux deux : les champs sont identiques, et deux
  /// écrans auraient divergé — celui de modification aurait fini par ne plus
  /// proposer la carte, comme la création avant sa correction.
  final SavedAddress? existing;

  const _AddressFormScreen({this.existing});

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
  /// Composantes issues du géocodage inverse, **jamais saisies à la main**.
  ///
  /// Restent nulles sur une adresse modifiée sans repasser par la carte, et
  /// c'est voulu : le serveur ne touche pas aux clés absentes, donc ce qu'un
  /// passage précédent avait établi survit. Les envoyer vides l'effacerait.
  String? _neighborhood;
  String? _city;
  String? _district;
  String? _province;
  String? _postalCode;
  String? _country;
  bool _saving = false;

  /// Adresse principale : préremplit le retrait à la création d'une nouvelle
  /// livraison.
  bool _isDefault = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final a = widget.existing;
    if (a == null) return;

    _name.text = a.name;
    // `street1`, jamais `address` : ce dernier est recomposé par Fleetbase à
    // partir du nom ET de la rue. Le remettre dans le champ puis réenregistrer
    // empilerait le nom devant la rue à chaque modification.
    //
    // Pas de repli sur `address` quand la rue est vide : sur les adresses
    // enregistrées avant cette correction, l'accesseur ne contient que le nom
    // du lieu — le reprendre écrirait « BOULANGERIE TEST » dans la rue. Un
    // champ vide dit la vérité : rien n'a jamais été enregistré là.
    _address.text = a.street1;
    _contact.text = a.contactName ?? '';
    _phone.text = a.contactPhone ?? '';
    _isDefault = a.isDefault;
    // Une adresse enregistrée sans coordonnées exploitables laisse le point
    // nul : le formulaire redemandera de le placer, plutôt que de reconduire
    // un point faux qui empoisonnerait chaque livraison qui la réutilise.
    if (a.latitude != 0 || a.longitude != 0) {
      _point = LatLng(a.latitude, a.longitude);
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _address, _contact, _phone]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Place le point, puis propose de reprendre son libellé dans le champ
  /// Adresse.
  ///
  /// Rempli sans demander seulement si le champ est vide — sinon, écraser
  /// silencieusement effacerait un texte saisi à la main, parfois plus
  /// précis que le géocodage inverse (numéro de porte, étage). La question
  /// ne se pose que si la position choisie a un libellé : sans lui, il n'y a
  /// rien à proposer.
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

    // La commune est retenue même si le commerçant refuse le libellé : elle
    // ne s'affiche nulle part et ne peut donc rien écraser, mais c'est un des
    // rares champs structurés que nous ayons — et depuis le 31/07/2026 c'est
    // par eux seuls que l'adresse d'une course non réclamée est recomposée,
    // l'accesseur `address` de Fleetbase contenant le nom du destinataire.
    setState(() {
      _point = result.point;
      _neighborhood = result.neighborhood;
      _city = result.city;
      _district = result.district;
      _province = result.province;
      _postalCode = result.postalCode;
      _country = result.country;
    });

    final label = result.label.trim();
    if (label.isEmpty) return;

    if (_address.text.trim().isEmpty) {
      setState(() => _address.text = label);
      return;
    }

    // ⚠️ **Pas un `AppConfirmDialog`, et ce n'est pas un oubli.** Les deux
    // boutons sont deux choix légitimes — « Garder mon texte » n'est pas un
    // retrait, c'est une décision aussi valable que « Remplacer ». Le passer en
    // confirmation baptiserait l'un des deux « annuler », et peindrait l'autre
    // en rouge alors que rien ici n'est destructeur : le champ est réécrit, il
    // n'est pas perdu.
    final replace = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remplacer l\'adresse ?'),
        content: Text(
          'Préremplir le champ Adresse avec « $label », la position que vous '
          'venez de sélectionner sur la carte ?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Garder mon texte'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remplacer'),
          ),
        ],
      ),
    );

    if (replace == true && mounted) {
      setState(() => _address.text = label);
    }
  }

  /// Seuls le nom et le téléphone sont obligatoires (décision produit,
  /// 30/07/2026) : l'adresse texte et la position se complètent souvent après
  /// coup, une fois le lieu connu plus précisément.
  Future<void> _save() async {
    final navigator = Navigator.of(context);
    final orderState = context.read<MerchantOrderState>();

    if (_name.text.trim().isEmpty || _phone.text.trim().isEmpty) {
      // Un refus, donc le ton d'un refus : ce message s'affichait comme une
      // confirmation, au même endroit et de la même couleur qu'« Adresse
      // enregistrée » deux gestes plus tôt.
      showAppError(
        context,
        _name.text.trim().isEmpty
            ? 'Le nom est obligatoire'
            : 'Le téléphone est obligatoire',
      );
      return;
    }

    setState(() => _saving = true);
    final ok = _isEdit
        ? await orderState.updateAddress(
            widget.existing!.id,
            label: 'commerce',
            name: _name.text.trim(),
            address: _address.text.trim(),
            neighborhood: _neighborhood,
            city: _city,
            district: _district,
            province: _province,
            postalCode: _postalCode,
            country: _country,
            latitude: _point?.latitude,
            longitude: _point?.longitude,
            contactName: _contact.text.trim(),
            contactPhone: _phone.text.trim(),
            isDefault: _isDefault,
          )
        : await orderState.saveAddress(
            label: 'commerce',
            name: _name.text.trim(),
            address: _address.text.trim(),
            neighborhood: _neighborhood,
            city: _city,
            district: _district,
            province: _province,
            postalCode: _postalCode,
            country: _country,
            latitude: _point?.latitude,
            longitude: _point?.longitude,
            contactName: _contact.text.trim(),
            contactPhone: _phone.text.trim(),
            isDefault: _isDefault,
          );
    if (!mounted) return;
    setState(() => _saving = false);

    if (ok) {
      navigator.pop(true);
    } else {
      showAppError(
        context,
        orderState.errorMessage ?? 'Enregistrement impossible',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Modifier l\'adresse' : 'Nouvelle adresse'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _field(_name, 'Nom *', Icons.label_outline),
              _field(_address, 'Adresse', Icons.place_outlined),
              _field(_contact, 'Contact', Icons.person_outline),
              _field(_phone, 'Téléphone *', Icons.phone_outlined,
                  keyboard: TextInputType.phone),
              const SizedBox(height: AppSpacing.sm),
              FilledButton.tonalIcon(
                onPressed: _pickOnMap,
                icon: const Icon(Icons.map_outlined),
                label: Text(_point == null
                    ? 'Placer sur la carte'
                    : 'Modifier la position'),
              ),
              const SizedBox(height: AppSpacing.sm),
              // Optionnelle, mais son absence a une conséquence concrète à
              // dire : sans elle, cette adresse ne pourra pas servir telle
              // quelle à une commande tant qu'elle n'aura pas été complétée.
              Row(
                children: [
                  Icon(
                    _point == null ? Icons.info_outline : Icons.check_circle_outline,
                    size: 16,
                    color: _point == null
                        ? Theme.of(context).colorScheme.onSurfaceVariant
                        : context.semantic.success,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _point == null
                          ? 'Position non définie (facultatif) — à compléter '
                              'avant de commander avec cette adresse'
                          : 'Position définie',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _isDefault,
                onChanged: (v) => setState(() => _isDefault = v),
                title: const Text('Adresse principale'),
                subtitle: Text(
                  'Préremplit le retrait à chaque nouvelle livraison. '
                  'Une seule adresse principale à la fois.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              FilledButton.icon(
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
        padding: const EdgeInsets.only(bottom: AppSpacing.md),
        child: TextField(
          controller: controller,
          keyboardType: keyboard,
          decoration: InputDecoration(
            labelText: label,
            prefixIcon: Icon(icon),
            isDense: true,
          ),
        ),
      );
}
