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

  String _t(String key) => fleetLabel(key, context.watch<LocaleState>().locale);

  @override
  Widget build(BuildContext context) {
    final state = context.watch<FleetState>();

    return Scaffold(
      appBar: AppBar(
        title: Text(_t('fleet.title')),
        actions: [
          IconButton(
            icon: const Icon(Icons.account_balance_wallet_outlined),
            tooltip: _t('fleet.tab.cash'),
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
            Tab(text: _t('fleet.tab.orders')),
            Tab(text: _t('fleet.tab.opportunities')),
            Tab(text: _t('fleet.tab.drivers')),
          ],
        ),
      ),
      body: state.isLoading && state.orders.isEmpty
          ? Center(child: Text(_t('fleet.loading')))
          : RefreshIndicator(
              onRefresh: () => context.read<FleetState>().load(),
              child: TabBarView(
                controller: _tabs,
                children: [
                  _OrdersTab(t: _t),
                  _OpportunitiesTab(t: _t),
                  _DriversTab(t: _t),
                ],
              ),
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
            '${_amount(meta, t)}\n${t('fleet.opportunities.masked')}',
          ),
          isThreeLine: true,
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
    if (state.drivers.isEmpty) {
      return _Empty(title: t('fleet.drivers.empty'), hint: '');
    }

    return ListView.separated(
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
    );
  }
}

String _dropoffLabel(Map<String, dynamic> order) {
  final payload = order['payload'] as Map<String, dynamic>?;
  final dropoff = payload?['dropoff'] as Map<String, dynamic>?;
  return (dropoff?['name'] ?? dropoff?['locality'] ?? order['public_id'] ?? '—')
      .toString();
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
