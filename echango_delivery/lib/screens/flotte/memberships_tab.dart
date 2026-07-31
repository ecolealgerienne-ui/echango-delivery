import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/fleet_strings.dart';
import '../../state/fleet_state.dart';

/// Les rattachements de l'entreprise, et le moyen d'en demander un nouveau.
///
/// ── Pourquoi un onglet distinct de « Conducteurs » ────────────────────────
///
/// « Conducteurs » répond à *« à qui puis-je confier une course »* — donc
/// uniquement les rattachements **actifs**. Cet onglet-ci répond à *« où en est
/// ma demande »*, et montre aussi ce qui est en attente, refusé ou suspendu.
/// Les fusionner ferait apparaître dans le sélecteur de conducteur des gens qui
/// n'ont pas encore accepté — c'est-à-dire à qui l'entreprise n'a pas le droit
/// de confier d'espèces.
///
/// ── Chercher avant de créer, et l'écran doit le dire ──────────────────────
///
/// Le bouton de création est **sous** la recherche, et accompagné de la raison :
/// si la personne roule déjà pour quelqu'un, la recréer produit deux `Driver`
/// Fleetbase pour un seul être humain, dont la position et l'historique
/// divergent aussitôt. Le serveur refuse le doublon de toute façon
/// (`driver.already_in_network`), mais un refus après coup se vit comme un bug ;
/// une phrase avant se vit comme une consigne.
class MembershipsTab extends StatefulWidget {
  const MembershipsTab({super.key, required this.t, required this.onCreateDriver});

  final String Function(String key) t;
  final Future<void> Function() onCreateDriver;

  @override
  State<MembershipsTab> createState() => _MembershipsTabState();
}

class _MembershipsTabState extends State<MembershipsTab> {
  final _search = TextEditingController();

  List<Map<String, dynamic>> _results = const [];
  String? _searchError;
  bool _searching = false;
  bool _searched = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<FleetState>().loadMemberships();
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _runSearch() async {
    final query = _search.text.trim();
    // Trois caractères : la contrainte du serveur (`DriverSearchDto`). La
    // reproduire ici évite un aller-retour pour une erreur qu'on connaît déjà.
    if (query.length < 3) return;

    setState(() {
      _searching = true;
      _searchError = null;
    });

    final outcome = await context.read<FleetState>().searchNetworkDrivers(query);
    if (!mounted) return;

    setState(() {
      _results = outcome.results;
      _searchError = outcome.error;
      _searching = false;
      _searched = true;
    });
  }

  Future<void> _request(String driverUuid) async {
    final t = widget.t;
    final error = await context.read<FleetState>().requestMembership(driverUuid);
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error ?? t('fleet.members.requested'))),
    );

    if (error == null) await _runSearch();
  }

  Future<void> _setSuspended(String membershipId, bool suspended) async {
    final error =
        await context.read<FleetState>().setMembershipSuspended(membershipId, suspended);
    if (!mounted || error == null) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    final state = context.watch<FleetState>();
    final memberships = state.memberships;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: _search,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _runSearch(),
          decoration: InputDecoration(
            labelText: t('fleet.members.search'),
            hintText: t('fleet.members.search.hint'),
            suffixIcon: IconButton(
              icon: const Icon(Icons.search),
              onPressed: _searching ? null : _runSearch,
            ),
          ),
        ),
        const SizedBox(height: 8),

        if (_searching) Text(t('fleet.loading')),

        if (_searchError != null)
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: ListTile(
              leading: const Icon(Icons.error_outline),
              title: Text(_searchError!),
            ),
          ),

        // ⚠️ « Personne de ce nom » n'est affirmé qu'après une recherche
        // effectivement aboutie : l'afficher pendant le chargement, ou après une
        // erreur, dirait que la personne n'existe pas alors qu'on n'en sait rien.
        if (_searched && !_searching && _searchError == null && _results.isEmpty)
          ListTile(
            leading: const Icon(Icons.person_off_outlined),
            title: Text(t('fleet.members.search.none')),
          ),

        for (final row in _results) _SearchResult(row: row, t: t, onRequest: _request),

        const Divider(height: 32),

        ListTile(
          leading: const Icon(Icons.person_add_alt_1),
          title: Text(t('fleet.members.create')),
          subtitle: Text(t('fleet.members.create.hint')),
          onTap: widget.onCreateDriver,
        ),

        const Divider(height: 32),

        if (memberships.isEmpty)
          ListTile(
            title: Text(t('fleet.members.empty')),
            subtitle: Text(t('fleet.members.empty.hint')),
          ),

        for (final m in memberships)
          _MembershipRow(membership: m, t: t, onSuspendedChanged: _setSuspended),
      ],
    );
  }
}

class _SearchResult extends StatelessWidget {
  const _SearchResult({required this.row, required this.t, required this.onRequest});

  final Map<String, dynamic> row;
  final String Function(String key) t;
  final Future<void> Function(String driverUuid) onRequest;

  @override
  Widget build(BuildContext context) {
    final uuid = row['driver_uuid'] as String?;
    final origin = row['origin'] == true;
    final status = row['membership'] as String?;

    // Déjà des nôtres, ou déjà demandé : on montre l'état plutôt qu'un bouton
    // qui produirait un refus — un bouton qui échoue toujours se lit comme une
    // panne, pas comme une règle.
    //
    // Deux informations distinctes, et la seconde compte au moment de décider :
    // l'état du rattachement, et le fait que la personne puisse répondre.
    final parts = <String>[
      if (origin)
        t('fleet.members.origin')
      else if (status != null)
        t('fleet.members.status.$status'),
      if (row['has_account'] == false) t('fleet.members.no_account'),
    ];
    final label = parts.isEmpty ? null : parts.join(' — ');

    return ListTile(
      leading: const Icon(Icons.person_outline),
      title: Text(row['name'] as String? ?? '—'),
      subtitle: label == null ? null : Text(label),
      trailing: (origin || status == 'pending' || status == 'active' || uuid == null)
          ? null
          : TextButton(
              onPressed: () => onRequest(uuid),
              child: Text(t('fleet.members.request')),
            ),
    );
  }
}

class _MembershipRow extends StatelessWidget {
  const _MembershipRow({
    required this.membership,
    required this.t,
    required this.onSuspendedChanged,
  });

  final Map<String, dynamic> membership;
  final String Function(String key) t;
  final Future<void> Function(String id, bool suspended) onSuspendedChanged;

  @override
  Widget build(BuildContext context) {
    final id = membership['id'] as String?;
    final status = membership['status'] as String? ?? 'pending';

    // Seuls deux états offrent une action, et il n'y a **jamais de
    // suppression** : la dette d'un conducteur envers l'entreprise survit à leur
    // séparation, et effacer la ligne emporterait la trace du lien qui
    // l'explique.
    Widget? action;
    if (id != null && status == 'active') {
      action = TextButton(
        onPressed: () => onSuspendedChanged(id, true),
        child: Text(t('fleet.members.suspend')),
      );
    } else if (id != null && status == 'suspended') {
      action = TextButton(
        onPressed: () => onSuspendedChanged(id, false),
        child: Text(t('fleet.members.reactivate')),
      );
    }

    return ListTile(
      leading: Icon(
        status == 'active' ? Icons.link : Icons.link_off,
        color: status == 'active' ? Colors.green : Theme.of(context).colorScheme.outline,
      ),
      title: Text(membership['name'] as String? ?? '—'),
      subtitle: Text(t('fleet.members.status.$status')),
      trailing: action,
    );
  }
}
