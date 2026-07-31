import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../i18n/fleet_strings.dart';
import '../../state/auth_state.dart';
import '../../state/fleet_state.dart';
import '../../state/locale_state.dart';
import '../../widgets/language_selector.dart';

/// Espace « entreprise de transport ».
///
/// Remplace `FlottePlaceholderScreen`, qui affichait « Espace non disponible »
/// alors que six routes BFF l'attendaient depuis le 28/07 (défaut D20).
///
/// ── Pourquoi un seul écran à onglets, et non quatre routes ─────────────────
///
/// Les quatre vues d'une entreprise se lisent ensemble : on prend une course
/// libre, on lui désigne un conducteur, et on regarde ce qu'on doit. Les
/// séparer en routes obligerait à recharger à chaque aller-retour, alors que
/// `FleetState.load()` sert les trois listes d'un coup — et une prise de course
/// fait justement passer une ligne d'un onglet à l'autre.
///
/// ── Les libellés passent par `fleetLabel()` ────────────────────────────────
///
/// Règle 4 : aucune chaîne en dur. Les écrans existants en portent ~575,
/// assumées comme dette ; un écran **neuf** n'a pas à la faire grandir.
class FlotteHomeScreen extends StatefulWidget {
  const FlotteHomeScreen({super.key});

  @override
  State<FlotteHomeScreen> createState() => _FlotteHomeScreenState();
}

class _FlotteHomeScreenState extends State<FlotteHomeScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  @override
  void initState() {
    super.initState();
    // Après la première frame : `load()` notifie, et notifier pendant la
    // construction d'un widget lève. Le défaut est classique et silencieux en
    // release.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<FleetState>().load();
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // ⚠️ La locale est capturée ici, dans `build`, et la fermeture ne retient
    // qu'elle — jamais le `BuildContext`.
    //
    // La version précédente faisait `context.watch<LocaleState>()` dans une
    // méthode passée aux sous-widgets ET appelée depuis deux callbacks
    // (`_claim`, `_pickDriver`). `watch` hors d'une phase de build lève chez
    // Provider : les deux actions principales de l'écran plantaient en debug.
    // `flutter analyze` ne le voit pas — c'est une règle d'exécution, pas de
    // typage.
    final locale = context.watch<LocaleState>().locale;
    String t(String key) => fleetLabel(key, locale);

    final state = context.watch<FleetState>();

    return Scaffold(
      appBar: AppBar(
        title: Text(t('fleet.title')),
        actions: [
          IconButton(
            icon: const Icon(Icons.account_balance_wallet_outlined),
            tooltip: t('fleet.tab.cash'),
            onPressed: () => context.push('/flotte/caisse'),
          ),
          const LanguageSelector(),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => context.read<AuthState>().logout(),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabs: [
            Tab(text: t('fleet.tab.orders')),
            Tab(text: t('fleet.tab.opportunities')),
            Tab(text: t('fleet.tab.drivers')),
          ],
        ),
      ),
      body: state.isLoading && state.orders.isEmpty
          ? Center(child: Text(t('fleet.loading')))
          : Column(
              children: [
                // ⚠️ Sans ce bandeau, une flotte inactive, un jeton expiré ou
                // un BFF injoignable produisaient l'écran « Aucune course
                // confiée à votre entreprise » — un message qui affirme un
                // fait faux. Le même défaut a été corrigé deux fois ailleurs.
                if (state.errorMessage != null)
                  Card(
                    margin: const EdgeInsets.all(12),
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: ListTile(
                      leading: const Icon(Icons.error_outline),
                      title: Text(state.errorMessage!),
                      trailing: TextButton(
                        onPressed: () => context.read<FleetState>().load(),
                        child: Text(t('fleet.retry')),
                      ),
                    ),
                  ),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: () => context.read<FleetState>().load(),
                    child: TabBarView(
                      controller: _tabs,
                      children: [
                        _OrdersTab(t: t),
                        _OpportunitiesTab(t: t),
                        _DriversTab(t: t),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

typedef _Translate = String Function(String key);

/// Message d'absence, toujours accompagné de ce qu'il faut faire.
///
/// Une liste vide sans explication se lit comme une panne — c'est le défaut
/// des deux impasses d'écran corrigées le 29/07 (« Mes transporteurs » sans
/// moyen d'en trouver un).
class _Empty extends StatelessWidget {
  const _Empty({required this.title, required this.hint});

  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        const SizedBox(height: 48),
        Icon(Icons.inbox_outlined, size: 64, color: theme.colorScheme.outline),
        const SizedBox(height: 16),
        Text(title, textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(hint, textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
      ],
    );
  }
}

class _OrdersTab extends StatelessWidget {
  const _OrdersTab({required this.t});

  final _Translate t;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<FleetState>();
    if (state.orders.isEmpty) {
      return _Empty(
        title: t('fleet.orders.empty'),
        hint: t('fleet.orders.empty.hint'),
      );
    }

    return ListView.separated(
      itemCount: state.orders.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final order = state.orders[i];
        final meta = order['meta'] as Map<String, dynamic>? ?? const {};
        final hasDriver = order['driver_assigned_uuid'] != null;

        return ListTile(
          title: Text(_dropoffLabel(order)),
          subtitle: Text(
            '${t('fleet.orders.status')} : ${order['status'] ?? '—'}\n'
            '${hasDriver ? t('fleet.orders.assigned_to') : t('fleet.orders.unassigned')}'
            '${_amount(meta, t)}',
          ),
          isThreeLine: true,
          // La ligne mène à la fiche. Sans elle, l'entreprise ne voyait jamais
          // ni l'adresse, ni les instructions, ni le contact d'une course
          // pourtant à elle — elle ne pouvait rien dire à son conducteur.
          onTap: () => context.push('/flotte/commandes/${order['uuid'] ?? ''}'),
          trailing: hasDriver
              ? null
              : TextButton(
                  onPressed: () => _pickDriver(context, order, t),
                  child: Text(t('fleet.orders.assign')),
                ),
        );
      },
    );
  }
}

class _OpportunitiesTab extends StatelessWidget {
  const _OpportunitiesTab({required this.t});

  final _Translate t;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<FleetState>();
    if (state.opportunities.isEmpty) {
      return _Empty(
        title: t('fleet.opportunities.empty'),
        hint: t('fleet.opportunities.empty.hint'),
      );
    }

    return ListView.separated(
      itemCount: state.opportunities.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final order = state.opportunities[i];
        final meta = order['meta'] as Map<String, dynamic>? ?? const {};
        final uuid = order['uuid'] as String? ?? '';
        final claiming = state.claimingOrderId == uuid;

        return ListTile(
          title: Text(_dropoffLabel(order)),
          subtitle: Text(
            '${_amount(meta, t)}\n${t('fleet.opportunities.masked')}'.trim(),
          ),
          isThreeLine: true,
          // ⚠️ La question du 31/07 était « sur quels critères je dois accepter
          // cette course ? ». La liste ne pouvait pas y répondre seule : le
          // détour, l'accès, l'heure prévue tiennent dans la fiche. Le bouton
          // « Prendre » reste sur la ligne pour ceux qui n'en ont pas besoin.
          onTap: () => context.push('/flotte/opportunites/$uuid'),
          trailing: FilledButton(
            onPressed: claiming ? null : () => _claim(context, uuid, t),
            child: Text(
              claiming ? t('fleet.opportunities.taking') : t('fleet.opportunities.take'),
            ),
          ),
        );
      },
    );
  }
}

class _DriversTab extends StatelessWidget {
  const _DriversTab({required this.t});

  final _Translate t;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<FleetState>();

    // ⚠️ L'action d'ajout est offerte dans les DEUX cas, pas seulement quand la
    // liste est vide. Sans elle, une entreprise nouvellement inscrite pouvait
    // prendre des courses et **n'en assigner aucune, définitivement** — la même
    // impasse que « Mes transporteurs » sans moyen d'en trouver un (29/07).
    final add = FloatingActionButton.extended(
      onPressed: () => _addDriver(context, t),
      icon: const Icon(Icons.person_add_alt),
      label: Text(t('fleet.drivers.add')),
    );

    if (state.drivers.isEmpty) {
      return Scaffold(
        body: _Empty(title: t('fleet.drivers.empty'), hint: t('fleet.drivers.add')),
        floatingActionButton: add,
      );
    }

    return Scaffold(
      floatingActionButton: add,
      body: ListView.separated(
      itemCount: state.drivers.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final driver = state.drivers[i];
        final online = driver['online'] == true;
        return ListTile(
          leading: Icon(
            Icons.circle,
            size: 12,
            color: online ? Colors.green : Colors.grey,
          ),
          title: Text(driver['name'] as String? ?? '—'),
          subtitle: Text(driver['phone'] as String? ?? ''),
          trailing: Text(
            online ? t('fleet.drivers.online') : t('fleet.drivers.offline'),
          ),
        );
      },
      ),
    );
  }
}

/// Créer un conducteur, et le rattacher à l'entreprise.
///
/// Le BFF fait les deux d'un geste. Le conducteur devra ensuite recevoir une
/// invitation pour créer son compte applicatif — il existe chez Fleetbase, il
/// n'a pas encore d'accès.
Future<void> _addDriver(BuildContext context, _Translate t) async {
  final nameCtrl = TextEditingController();
  final emailCtrl = TextEditingController();
  final phoneCtrl = TextEditingController();

  final submitted = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(t('fleet.drivers.add')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: nameCtrl,
            decoration: InputDecoration(labelText: t('fleet.drivers.name')),
          ),
          TextField(
            controller: emailCtrl,
            keyboardType: TextInputType.emailAddress,
            decoration: InputDecoration(labelText: t('fleet.drivers.email')),
          ),
          TextField(
            controller: phoneCtrl,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(labelText: t('fleet.drivers.phone')),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(t('fleet.cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(t('fleet.confirm')),
        ),
      ],
    ),
  );

  final name = nameCtrl.text.trim();
  final email = emailCtrl.text.trim();
  final phone = phoneCtrl.text.trim();
  nameCtrl.dispose();
  emailCtrl.dispose();
  phoneCtrl.dispose();

  if (submitted != true || !context.mounted) return;
  if (name.isEmpty || email.isEmpty) return;

  final error = await context
      .read<FleetState>()
      .addDriver(name: name, email: email, phone: phone);

  if (!context.mounted || error == null) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
}

/// Où va la course.
///
/// ⚠️ **Plus de branche `unclaimed`** (31/07/2026). L'expurgation posait
/// `name: 'Destinataire'` en dur sur une course libre, ce qui titrait toutes les
/// lignes du même mot ; il fallait donc lire `address` d'abord dans ce cas-là et
/// `name` dans l'autre. Depuis que le serveur ne masque plus que l'identité,
/// `name` est **absent** sur une course libre au lieu d'être remplacé — la
/// chaîne de replis suffit, et une seule règle vaut pour les deux onglets.
///
/// L'ordre a son importance : `name` porte le libellé du carnet d'adresses,
/// plus parlant qu'une adresse formatée quand il existe.
String _dropoffLabel(Map<String, dynamic> order) {
  final payload = order['payload'] as Map<String, dynamic>?;
  final dropoff = payload?['dropoff'] as Map<String, dynamic>?;

  for (final candidate in [
    dropoff?['name'],
    dropoff?['address'],
    dropoff?['street1'],
    dropoff?['city'],
    order['public_id'],
  ]) {
    // ⚠️ `??` ne suffit pas : `address` vaut `''` quand le commerçant a saisi
    // une adresse sans passer par la carte, et une chaîne vide n'est pas nulle.
    // La ligne restait alors titrée par du blanc.
    if (candidate is String && candidate.trim().isNotEmpty) return candidate.trim();
  }
  return '—';
}

/// Les deux montants, quand ils existent.
///
/// ⚠️ Ils viennent des **champs personnalisés** recomposés par le serveur, et
/// non du `meta` brut de Fleetbase : c'est le défaut D6, corrigé au Lot 2. Sans
/// cette recomposition, une entreprise décidait de prendre une course sans voir
/// ni ce qu'elle rapporte ni ce qu'il faudra encaisser.
String _amount(Map<String, dynamic> meta, _Translate t) {
  final price = meta['price'];
  final cod = meta['cod_amount'];
  final parts = <String>[];
  if (price != null) parts.add('${t('fleet.orders.price')} : $price');
  if (cod != null) parts.add('${t('fleet.orders.cod')} : $cod');
  return parts.isEmpty ? '' : '\n${parts.join(' — ')}';
}

Future<void> _claim(BuildContext context, String uuid, _Translate t) async {
  final error = await context.read<FleetState>().claim(uuid);
  if (!context.mounted) return;

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(error ?? t('fleet.opportunities.taken'))),
  );
}

/// Choisir un conducteur parmi ceux de l'entreprise.
///
/// La liste vient de `GET /flotte/drivers`, donc déjà bornée aux siens : le
/// serveur revérifie de toute façon l'appartenance du conducteur ET de la
/// course avant d'appeler Fleetbase (anti-IDOR validé entre deux flottes le
/// 28/07). L'écran ne fait que présenter, il n'autorise pas.
Future<void> _pickDriver(
  BuildContext context,
  Map<String, dynamic> order,
  _Translate t,
) async {
  final state = context.read<FleetState>();
  final drivers = state.drivers;

  if (drivers.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(t('fleet.drivers.empty'))),
    );
    return;
  }

  final chosen = await showModalBottomSheet<String>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          ListTile(title: Text(t('fleet.drivers.select'))),
          const Divider(height: 1),
          for (final driver in drivers)
            ListTile(
              title: Text(driver['name'] as String? ?? '—'),
              subtitle: Text(driver['phone'] as String? ?? ''),
              onTap: () => Navigator.of(sheetContext).pop(driver['uuid'] as String?),
            ),
        ],
      ),
    ),
  );

  if (chosen == null || !context.mounted) return;

  final error = await state.assignDriver(order['uuid'] as String? ?? '', chosen);
  if (!context.mounted) return;

  if (error != null) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }
}
