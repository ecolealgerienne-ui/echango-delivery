import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/merchant_order.dart';
import '../../services/bff_api_client.dart';
import '../../state/merchant_order_state.dart';
import '../../config/app_rules.dart';
import '../../theme/app_spacing.dart';

/// Transporteurs habituels du commerçant.
///
/// ── Pourquoi des favoris et non une assignation directe ─────────────────────
///
/// La thèse du produit est l'effet réseau : un pool **mutualisé**. Laisser un
/// commerçant désigner nommément son transporteur ferait glisser la place de
/// marché vers des relations bilatérales, et les nouveaux entrants ne
/// démarreraient jamais faute d'être choisis. Les favoris sont sollicités en
/// premier, et la course retombe dans le pool si aucun n'est libre : la
/// préférence est respectée, la liquidité du réseau préservée.
///
/// ── Deux chemins pour trouver quelqu'un ────────────────────────────────────
///
/// **Ceux qui ont déjà livré** pour ce commerçant : la source naturelle, elle
/// se remplit toute seule.
///
/// **La recherche par nom ou téléphone** : pour le cas où la relation existe
/// hors de l'application — le coursier a laissé son numéro, un confrère l'a
/// recommandé. Ce n'est **pas un annuaire** : au-delà de dix correspondances le
/// serveur demande de préciser. Un annuaire parcourable livrerait la
/// composition du réseau à quiconque crée un compte, et n'aiderait personne —
/// trente noms inconnus ne s'ordonnent pas, on choisirait au hasard.
class FavouriteDriversScreen extends StatefulWidget {
  const FavouriteDriversScreen({super.key});

  @override
  State<FavouriteDriversScreen> createState() => _FavouriteDriversScreenState();
}

class _FavouriteDriversScreenState extends State<FavouriteDriversScreen> {
  List<KnownDriver> _known = [];
  bool _loading = true;
  String? _error;

  final _searchController = TextEditingController();
  List<KnownDriver> _results = [];
  bool _searching = false;
  bool _tooMany = false;
  /// Distingue « pas encore cherché » de « cherché, rien trouvé » : les deux
  /// donnent une liste vide, et les confondre afficherait « aucun résultat »
  /// avant la moindre frappe.
  bool _searched = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _searchController.text.trim();
    if (query.length < ServerRules.driverSearchMinLength) {
      setState(() {
        _searched = false;
        _results = [];
        _tooMany = false;
      });
      return;
    }

    final api = context.read<BffApiClient>();
    setState(() => _searching = true);
    try {
      final result = await api.searchDrivers(query);
      if (!mounted) return;
      setState(() {
        _results = result.drivers;
        _tooMany = result.tooMany;
        _searched = true;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Recherche impossible : $e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _addFavourite(MerchantOrderState state, KnownDriver d) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await state.addFavourite(d);
    if (!mounted) return;

    if (ok) {
      // Le résultat disparaît de la recherche une fois ajouté : le laisser
      // ferait douter que l'ajout ait eu lieu.
      setState(() => _results.removeWhere((r) => r.driverUuid == d.driverUuid));
    } else {
      messenger.showSnackBar(
        SnackBar(
          content: Text(state.errorMessage ?? 'Ajout impossible'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Les deux lectures de `context` AVANT tout `await` : après, le widget
      // peut avoir été démonté et `context` ne vaut plus rien.
      final state = context.read<MerchantOrderState>();
      final api = context.read<BffApiClient>();
      await state.loadFavourites();
      final known = await api.getKnownDrivers();
      if (mounted) setState(() => _known = known);
    } catch (e) {
      if (mounted) setState(() => _error = 'Chargement impossible : $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<MerchantOrderState>();
    final favouriteUuids = {for (final f in state.favourites) f.driverUuid};
    final candidates =
        _known.where((d) => !favouriteUuids.contains(d.driverUuid)).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Mes transporteurs')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(AppSpacing.lg),
                children: [
                  if (_error != null) ...[
                    Text(_error!,
                        style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    const SizedBox(height: AppSpacing.lg),
                  ],
                  // La recherche passe en tête : c'est le seul chemin dont
                  // dispose un commerçant nouveau, dont toutes les autres
                  // listes sont vides.
                  Text('Ajouter un transporteur',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: AppSpacing.sm),
                  TextField(
                    controller: _searchController,
                    onChanged: (_) => _search(),
                    decoration: InputDecoration(
                      hintText: 'Nom ou téléphone du transporteur',
                      prefixIcon: const Icon(Icons.search),
                      border: const OutlineInputBorder(),
                      isDense: true,
                      suffixIcon: _searching
                          ? const Padding(
                              padding: EdgeInsets.all(AppSpacing.md),
                              child: SizedBox(
                                height: 16,
                                width: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            )
                          : null,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Cherchez par le nom ou le téléphone communiqué par '
                    'Echango. Trois caractères minimum.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (_tooMany)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
                      child: Text(
                        'Trop de correspondances. Précisez le nom ou saisissez '
                        'le numéro de téléphone.',
                      ),
                    )
                  else if (_searched && _results.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
                      child: Text(
                        'Aucun transporteur ne correspond. Vérifiez le nom, ou '
                        'demandez-lui le numéro qu\'il a donné à Echango.',
                      ),
                    )
                  else
                    ..._results.map(
                      (d) => Card(
                        child: ListTile(
                          leading: const Icon(Icons.person_search_outlined),
                          title: Text(d.displayName),
                          // Un transporteur de l'annuaire qui n'a pas encore
                          // l'application ne recevra aucune course : le mettre
                          // en favori serait un geste sans effet, et le taire
                          // ferait croire la préférence enregistrée.
                          subtitle: d.hasAccount
                              ? null
                              : Text(
                                  'N\'a pas encore installé l\'application — '
                                  'aucune course ne lui sera proposée pour '
                                  'l\'instant.',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                          trailing: IconButton(
                            icon: const Icon(Icons.star_outline),
                            tooltip: 'Ajouter aux favoris',
                            onPressed: () => _addFavourite(state, d),
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: AppSpacing.xl),
                  Text('Favoris', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: AppSpacing.sm),
                  if (state.favourites.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
                      child: Text(
                        'Aucun favori. Vos livraisons sont proposées à '
                        'l\'ensemble du réseau.',
                      ),
                    )
                  else
                    ...state.favourites.map(
                      (d) => Card(
                        child: ListTile(
                          leading: const Icon(Icons.star, color: Colors.amber),
                          title: Text(d.displayName),
                          trailing: IconButton(
                            icon: const Icon(Icons.remove_circle_outline),
                            tooltip: 'Retirer des favoris',
                            onPressed: d.favouriteId == null
                                ? null
                                : () => state.removeFavourite(d.favouriteId!),
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: AppSpacing.xl),
                  Text('Déjà intervenus pour vous',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: AppSpacing.sm),
                  if (candidates.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
                      child: Text(
                        'Aucun autre transporteur pour l\'instant. La liste se '
                        'remplit au fil de vos livraisons.',
                      ),
                    )
                  else
                    ...candidates.map(
                      (d) => Card(
                        child: ListTile(
                          leading: const Icon(Icons.person_outline),
                          title: Text(d.displayName),
                          trailing: IconButton(
                            icon: const Icon(Icons.star_outline),
                            tooltip: 'Ajouter aux favoris',
                            onPressed: () => _addFavourite(state, d),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
