import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'driver_picker.dart';
import '../../i18n/fleet_strings.dart';
import '../../models/order.dart';
import '../../services/navigation_launcher.dart';
import '../../state/fleet_state.dart';
import '../../state/locale_state.dart';

/// La fiche d'une course, vue par une entreprise de transport.
///
/// ── Pourquoi cet écran existe (décision produit du 31/07/2026) ─────────────
///
/// L'entreprise voyait une liste et **rien d'autre** : aucune ligne n'était
/// cliquable. Elle devait décider de prendre une course sur un titre et deux
/// montants — et le titre lui-même était « Destinataire » sur toutes les lignes,
/// puisque l'expurgation d'alors remplaçait le nom du lieu par ce mot. Décider
/// sans critère n'est pas décider.
///
/// Ce que la fiche montre est donc **tout** ce que le serveur sait de la course,
/// à une exception près : le nom et le téléphone du destinataire, qui
/// n'apparaissent qu'une fois l'entreprise engagée. C'est la seule chose qui
/// distingue une opportunité d'une course à soi, et le bandeau le dit — sans
/// quoi l'absence se lirait comme une donnée manquante.
///
/// ── Deux sources, une seule fiche ─────────────────────────────────────────
///
/// `unclaimed` décide de la route lue (`opportunites/:id` ou `commandes/:id`),
/// des champs présents, et de l'action en pied. Un écran par cas aurait
/// dupliqué la mise en page de neuf sections pour une différence qui tient en
/// trois conditions — et les deux copies auraient divergé, comme les deux
/// désérialiseurs Dart fusionnés le 28/07.
class FlotteOrderDetailScreen extends StatefulWidget {
  const FlotteOrderDetailScreen({
    super.key,
    required this.orderId,
    required this.unclaimed,
  });

  final String orderId;

  /// Course libre : lue par la route des opportunités, identité masquée, et le
  /// pied d'écran propose de la prendre plutôt que d'y désigner un conducteur.
  final bool unclaimed;

  @override
  State<FlotteOrderDetailScreen> createState() => _FlotteOrderDetailScreenState();
}

class _FlotteOrderDetailScreenState extends State<FlotteOrderDetailScreen> {
  Map<String, dynamic>? _order;
  String? _error;
  bool _loading = true;
  bool _claiming = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    // ⚠️ `_loading` ne vaut `true` que sur le **premier** chargement.
    //
    // Le mettre à chaque fois faisait disparaître la fiche — et le spinner du
    // geste en cours — dès qu'on tirait pour rafraîchir : le `RefreshIndicator`
    // était remplacé par « Chargement… » au premier pixel du geste.
    setState(() {
      _loading = _order == null;
      _error = null;
    });

    final result = await context
        .read<FleetState>()
        .fetchOrder(widget.orderId, unclaimed: widget.unclaimed);

    if (!mounted) return;
    setState(() {
      // ⚠️ On ne remplace la fiche que par une fiche. Un rafraîchissement raté
      // sur un réseau coupé jetait un contenu parfaitement lisible pour
      // afficher une erreur — l'utilisateur perdait ce qu'il était en train de
      // lire, à cause d'un geste censé l'enrichir.
      if (result.order != null) _order = result.order;
      _error = result.error;
      _loading = false;
    });
  }

  /// La réponse décrit-elle une course, ou seulement une enveloppe vide ?
  ///
  /// ⚠️ Le client HTTP ne rend **jamais `null`** : un corps vide devient `{}`.
  /// Sans cette vérification, un `{}` produisait une fiche entièrement blanche —
  /// aucune section, aucun message — **avec le bouton « Prendre cette course »
  /// actif**. C'est le motif « une valeur par défaut détruit l'information
  /// d'absence », ici dans sa forme la plus coûteuse : on propose de s'engager
  /// sur une course dont on ne sait rien.
  bool _describesAnOrder(Map<String, dynamic>? order) =>
      order != null && (order['uuid'] != null || order['public_id'] != null);

  @override
  Widget build(BuildContext context) {
    // Capturée dans `build`, comme sur l'écran d'accueil : `context.watch` hors
    // d'une phase de build lève chez Provider, et l'analyseur ne le voit pas.
    final locale = context.watch<LocaleState>().locale;
    String t(String key) => fleetLabel(key, locale);

    final order = _describesAnOrder(_order) ? _order : null;

    return Scaffold(
      appBar: AppBar(title: Text(t('fleet.detail.title'))),
      body: _loading
          ? Center(child: Text(t('fleet.loading')))
          : _error != null
              ? _Failure(message: _error!, retry: _load, t: t)
              : order == null
                  ? _Failure(message: t('fleet.detail.not_found'), retry: _load, t: t)
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: _Body(order: order, t: t),
                    ),
      bottomNavigationBar: order == null ? null : _action(order, t),
    );
  }

  /// L'action du bas dépend de ce que la course attend de l'entreprise :
  /// la prendre si elle est libre, lui désigner un conducteur si elle n'en a
  /// pas. Une fiche qui ne permet rien oblige à revenir à la liste pour agir,
  /// et c'est précisément l'impasse que cet écran existe pour lever.
  Widget? _action(Map<String, dynamic> order, _Translate t) {
    if (widget.unclaimed) {
      return _bar(
        FilledButton(
          onPressed: _claiming ? null : () => _claim(t),
          child: Text(
            _claiming ? t('fleet.opportunities.taking') : t('fleet.opportunities.take'),
          ),
        ),
      );
    }

    if (order['driver_assigned'] == null) {
      return _bar(
        FilledButton.icon(
          onPressed: () => _assign(order, t),
          icon: const Icon(Icons.person_add_alt),
          label: Text(t('fleet.orders.assign')),
        ),
      );
    }

    return null;
  }

  Widget _bar(Widget child) => SafeArea(
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      );

  Future<void> _assign(Map<String, dynamic> order, _Translate t) async {
    final error = await pickAndAssignDriver(context, order['uuid'] as String? ?? '', t);
    if (!mounted) return;

    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    // Le conducteur désigné change la fiche : on la relit plutôt que de la
    // supposer à jour.
    await _load();
  }

  Future<void> _claim(_Translate t) async {
    setState(() => _claiming = true);
    final error = await context.read<FleetState>().claim(widget.orderId);
    if (!mounted) return;
    setState(() => _claiming = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error ?? t('fleet.opportunities.taken'))),
    );

    if (error != null) return;

    // Prise réussie : la course a changé de camp, et cette fiche-ci lit la route
    // des opportunités, où elle n'est plus. Revenir à la liste plutôt que
    // recharger un écran qui répondrait « plus disponible » sur un succès.
    //
    // ⚠️ `canPop` d'abord : sur un lien profond ou une restauration d'URL, cette
    // fiche peut être la seule page de la pile, et `pop` lève alors.
    if (context.canPop()) {
      context.pop(true);
    } else {
      context.go('/flotte');
    }
  }
}

typedef _Translate = String Function(String key);

class _Failure extends StatelessWidget {
  const _Failure({required this.message, required this.retry, required this.t});

  final String message;
  final Future<void> Function() retry;
  final _Translate t;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        const SizedBox(height: 48),
        Icon(Icons.error_outline, size: 56, color: Theme.of(context).colorScheme.error),
        const SizedBox(height: 16),
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        Center(child: FilledButton(onPressed: retry, child: Text(t('fleet.retry')))),
      ],
    );
  }
}

/// ⚠️ **Pas de champ `unclaimed` ici**, alors que l'écran le connaît.
///
/// Il était déclaré, transmis, et **jamais lu** : tout le rendu s'appuie sur
/// `order['redacted']`, posé par le serveur. Un champ public d'une classe privée
/// n'est signalé par aucun lint, donc l'état mort serait resté — et le jour où
/// quelqu'un ajoute une branche, il aurait eu deux vérités au choix, celle du
/// routeur et celle du serveur, qui peuvent diverger dès que la règle de
/// masquage change en amont. C'est le `is_draft` de CLAUDE.md en miniature.
class _Body extends StatelessWidget {
  const _Body({required this.order, required this.t});

  final Map<String, dynamic> order;
  final _Translate t;

  @override
  Widget build(BuildContext context) {
    final meta = order['meta'] as Map<String, dynamic>? ?? const {};
    final payload = order['payload'] as Map<String, dynamic>? ?? const {};
    final pickup = payload['pickup'] as Map<String, dynamic>?;
    final dropoff = payload['dropoff'] as Map<String, dynamic>?;

    return ListView(
      // Sans ça, une fiche courte — une opportunité sans instructions ni colis
      // — ne défile pas, donc le geste de tirer-pour-rafraîchir ne part jamais
      // et le seul moyen de recharger devient de quitter l'écran.
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        // ⚠️ Le drapeau vient du serveur (`redacted`), il n'est pas déduit de
        // `unclaimed` : c'est le serveur qui décide de ce qu'il retire, et lui
        // seul sait s'il l'a fait. Le déduire ici afficherait la phrase même le
        // jour où la règle changerait en amont.
        if (order['redacted'] == true)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Card(
              color: Theme.of(context).colorScheme.secondaryContainer,
              child: ListTile(
                leading: const Icon(Icons.visibility_off_outlined),
                title: Text(t('fleet.opportunities.masked')),
              ),
            ),
          ),

        // ── L'état de la course ──────────────────────────────────────────
        //
        // ⚠️ `status` était dans la section « Ce que rapporte cette course ».
        // Il ne rapporte rien, et surtout il **neutralisait le masquage des
        // sections vides** : une course sans montant affichait quand même le
        // titre « Ce que rapporte cette course » au-dessus d'un « Statut :
        // created » solitaire, ce qui se lit comme « elle ne rapporte rien ».
        _Section(
          title: t('fleet.detail.section.state'),
          rows: [
            _Row(t('fleet.orders.status'), order['status']?.toString()),
            _Row(t('fleet.detail.scheduled'), order['scheduled_at']?.toString()),
            _Row(t('fleet.detail.distance'), _distance(order['distance'])),
            _Row(t('fleet.detail.tracking'), _tracking(order['tracking_number'])),
            _Row(t('fleet.orders.assigned_to'), _driver(order['driver_assigned'])),
          ],
        ),

        _Section(
          title: t('fleet.detail.section.money'),
          rows: [
            _Row(t('fleet.orders.price'), _money(meta['price'], meta['currency'])),
            _Row(t('fleet.orders.cod'), _money(meta['cod_amount'], meta['cod_currency'])),
            // La décomposition, quand elle existe : sans elle, un montant à la
            // porte plus élevé que le prix de la marchandise passe pour une
            // erreur de saisie.
            if (meta['cod_goods_amount'] != null)
              _Row(
                t('fleet.detail.goods'),
                _money(meta['cod_goods_amount'], meta['cod_currency']),
              ),
          ],
        ),

        _PlaceSection(
          title: t('fleet.detail.section.pickup'),
          place: pickup,
          notes: meta['pickup_notes'],
          t: t,
        ),

        _PlaceSection(
          title: t('fleet.detail.section.dropoff'),
          place: dropoff,
          notes: meta['dropoff_notes'],
          t: t,
        ),

        _Section(
          title: t('fleet.detail.section.parcel'),
          rows: [
            _Row(t('fleet.detail.items'), _items(meta['items'], t)),
            _Row(t('fleet.detail.vehicle'), meta['vehicle_type']?.toString()),
            _Row(t('fleet.detail.instructions'), meta['instructions']?.toString()),
            // Le texte libre du commerçant sur la commande. Projeté depuis
            // toujours et lu nulle part — sur un écran né de « je ne pouvais
            // rien dire à mon conducteur », c'est le champ le plus direct.
            _Row(t('fleet.detail.order_notes'), order['notes']?.toString()),
            if (order['pod_required'] == true)
              _Row(t('fleet.detail.pod'), order['pod_method']?.toString() ?? '✓'),
          ],
        ),

        const SizedBox(height: 24),
      ],
    );
  }
}

/// Un lieu, ses précisions, et les deux gestes qu'on fait dessus : y aller,
/// appeler. Le bouton d'appel n'apparaît que si un numéro est là — l'offrir
/// pour rien sur une course non réclamée ferait croire à une panne.
class _PlaceSection extends StatelessWidget {
  const _PlaceSection({
    required this.title,
    required this.place,
    required this.notes,
    required this.t,
  });

  final String title;
  final Map<String, dynamic>? place;
  final Object? notes;
  final _Translate t;

  @override
  Widget build(BuildContext context) {
    final source = place;
    if (source == null) return const SizedBox.shrink();

    final parsed = Place.fromJson(source);
    final phone = parsed.contactPhone;
    final contact = parsed.contactName;

    return _Section(
      title: title,
      rows: [
        _Row(t('fleet.detail.address'), _address(source, parsed)),
        if (contact != null && contact.isNotEmpty) _Row(t('fleet.detail.contact'), contact),
        if (notes != null && notes.toString().isNotEmpty)
          _Row(t('fleet.detail.notes'), notes.toString()),
      ],
      actions: [
        if (parsed.latitude != null && parsed.longitude != null)
          TextButton.icon(
            onPressed: () async {
              final ok = await NavigationLauncher.navigateTo(parsed);
              if (!context.mounted || ok) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(t('fleet.detail.no_map_app'))),
              );
            },
            icon: const Icon(Icons.map_outlined),
            label: Text(t('fleet.detail.open_map')),
          ),
        if (phone != null && phone.isNotEmpty)
          TextButton.icon(
            onPressed: () => NavigationLauncher.call(phone),
            icon: const Icon(Icons.phone_outlined),
            label: Text(phone),
          ),
      ],
    );
  }

  /// L'adresse la plus complète disponible.
  ///
  /// `Place.address` retombe déjà sur `street1`, mais ni l'un ni l'autre ne
  /// portent la commune quand le géocodeur l'a rangée dans `city` : une fiche
  /// n'affichant que la rue laisse ignorer de quel bout de la ville il s'agit,
  /// ce qui est justement le critère de décision.
  String _address(Map<String, dynamic> raw, Place parsed) {
    final parts = <String>[if (parsed.address.isNotEmpty) parsed.address.trim()];

    for (final key in ['neighborhood', 'city', 'postal_code', 'province']) {
      final value = raw[key];
      if (value is! String || value.trim().isEmpty) continue;
      final component = value.trim();

      // ⚠️ Le test est un **`contains`**, pas une égalité.
      //
      // `address` est déjà une phrase composée — par l'accesseur de Fleetbase
      // sur une course engagée, par le BFF sur une course libre — et elle
      // contient donc souvent la commune et le code postal. Une comparaison
      // stricte ne voyait pas « Bir Mourad Raïs » à l'intérieur de « 8 rue…,
      // Bir Mourad Raïs, 16000 » et les rajoutait : l'adresse se terminait par
      // sa propre fin, répétée.
      final already = parts.any(
        (p) => p.toLowerCase().contains(component.toLowerCase()),
      );
      if (!already) parts.add(component);
    }

    return parts.join(', ');
  }
}

class _Row {
  const _Row(this.label, this.value);
  final String label;
  final String? value;
}

/// Une section, qui **n'affiche pas ses lignes vides**.
///
/// Une fiche pleine de « — » se lit comme une commande incomplète alors qu'elle
/// est simplement sans instruction particulière. La section entière disparaît
/// si rien n'a de valeur.
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.rows,
    this.actions = const [],
  });

  final String title;
  final List<_Row> rows;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final filled = rows.where((r) => r.value != null && r.value!.trim().isNotEmpty).toList();
    if (filled.isEmpty && actions.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final row in filled)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 2,
                      child: Text(row.label, style: theme.textTheme.bodySmall),
                    ),
                    Expanded(
                      flex: 3,
                      child: Text(row.value!, style: theme.textTheme.bodyMedium),
                    ),
                  ],
                ),
              ),
            if (actions.isNotEmpty)
              Wrap(spacing: 8, children: actions),
          ],
        ),
      ),
    );
  }
}

/// Le conducteur désigné, tel que la projection flotte le sert.
///
/// Absent sur une course libre — par construction, une course que personne n'a
/// prise n'a pas de conducteur, et la projection ne l'émet plus dans ce cas.
String? _driver(Object? assigned) {
  if (assigned is! Map) return null;
  final name = assigned['name']?.toString().trim();
  final phone = assigned['phone']?.toString().trim();
  if (name == null || name.isEmpty) return phone;
  return phone == null || phone.isEmpty ? name : '$name — $phone';
}

String? _money(Object? amount, Object? currency) {
  if (amount == null) return null;
  final unit = currency?.toString();
  return unit == null || unit.isEmpty ? '$amount' : '$amount $unit';
}

/// Les colis, tels que le commerçant les a saisis.
///
/// ⚠️ `items` arrive en liste **ou** en chaîne JSON : le cast `array` des champs
/// personnalisés est inutilisable côté Fleetbase (il écrit avant de typer), donc
/// le BFF encode lui-même et tolère le double encodage. La fiche ne peut pas
/// présumer d'une forme — présumer la liste ferait disparaître le contenu du
/// colis, sans erreur.
String? _items(Object? items, _Translate t) {
  if (items == null) return null;
  if (items is List) {
    final labels = items.map((i) => _describeItem(i, t)).where((l) => l.isNotEmpty).join(', ');
    return labels.isEmpty ? null : labels;
  }
  final text = items.toString().trim();
  return text.isEmpty || text == '[]' ? null : text;
}

/// ⚠️ **Quantité, poids et fragilité compris**, et pas seulement la description.
///
/// La version précédente ne joignait que les descriptions : l'entreprise lisait
/// « Cartons » là où le commerçant avait saisi « Cartons ×8, 45 kg, fragile ».
/// Ce sont exactement les deux critères qui décident du véhicule — et comme la
/// description est complète en apparence, **rien ne signalait le manque**. C'est
/// la forme la plus coûteuse de l'omission : pas un blanc qu'on remarque, un
/// texte affirmatif incomplet.
String _describeItem(Object? item, _Translate t) {
  if (item is! Map) return item?.toString().trim() ?? '';

  final label = (item['name'] ?? item['description'])?.toString().trim() ?? '';
  if (label.isEmpty) return '';

  final quantity = item['quantity'];
  final weight = item['weight'];
  final details = <String>[
    if (quantity is num && quantity > 1) '×${quantity.toStringAsFixed(0)}',
    if (weight is num && weight > 0) '${weight.toStringAsFixed(weight % 1 == 0 ? 0 : 1)} kg',
    if (item['fragile'] == true) t('fleet.detail.fragile'),
  ];

  return details.isEmpty ? label : '$label (${details.join(', ')})';
}

String? _distance(Object? metres) {
  if (metres is! num || metres <= 0) return null;
  return metres >= 1000
      ? '${(metres / 1000).toStringAsFixed(1)} km'
      : '${metres.round()} m';
}

/// ⚠️ Fleetbase sert `tracking_number` tantôt en chaîne, tantôt en objet —
/// motif connu de l'amont, déjà rencontré sur `meta`. Afficher l'objet tel quel
/// donnerait `{tracking_number: ECH-…, qr_code: …}` à l'écran.
String? _tracking(Object? value) {
  if (value == null) return null;
  if (value is Map) return value['tracking_number']?.toString();
  return value.toString();
}
