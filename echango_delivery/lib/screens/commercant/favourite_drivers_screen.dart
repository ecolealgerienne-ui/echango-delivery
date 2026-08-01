import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/order_strings.dart';
import '../../models/merchant_order.dart';
import '../../services/bff_api_client.dart';
import '../../state/locale_state.dart';
import '../../state/merchant_order_state.dart';
import '../../config/app_rules.dart';
import '../../theme/app_semantic_colors.dart';
import '../../theme/app_spacing.dart';
import '../../widgets/app_snack_bar.dart';

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
  String _t(String key, [Map<String, String>? vars]) =>
      orderLabel(key, context.read<LocaleState>().locale, vars);

  List<KnownDriver> _known = [];
  bool _loading = true;

  /// Vrai jusqu'à ce que la première lecture ait abouti — d'où l'écran part.
  ///
  /// Seul ce premier chargement a le droit de remplacer le contenu : après, il
  /// y a quelque chose à l'écran, et l'effacer pour montrer une attente est une
  /// perte nette.
  bool _firstLoad = true;
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
      if (mounted) {
        setState(() =>
            _error = _t('order.fav.search.failed', {'error': '$e'}));
      }
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _addFavourite(MerchantOrderState state, KnownDriver d) async {
    final ok = await state.addFavourite(d);
    if (!mounted) return;

    if (ok) {
      // Le résultat disparaît de la recherche une fois ajouté : le laisser
      // ferait douter que l'ajout ait eu lieu.
      setState(() => _results.removeWhere((r) => r.driverUuid == d.driverUuid));
    } else {
      showAppError(context, state.errorMessage ?? _t('order.fav.add.failed'));
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
      if (mounted) {
        setState(() =>
            _error = _t('order.fav.load.failed', {'error': '$e'}));
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _firstLoad = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<MerchantOrderState>();
    final favouriteUuids = {for (final f in state.favourites) f.driverUuid};
    final candidates =
        _known.where((d) => !favouriteUuids.contains(d.driverUuid)).toList();

    return Scaffold(
      appBar: AppBar(title: Text(_t('order.fav.title'))),
      body: RefreshIndicator(
        onRefresh: _load,
        // ⚠️ `_firstLoad` et non `_loading`. Avec `_loading`, **tirer pour
        // recharger effaçait la liste** : le contenu était remplacé par un
        // second indicateur, sous celui que `RefreshIndicator` dessine
        // lui-même, et l'enfant cessait d'être défilable au milieu du geste qui
        // en dépend. Un rechargement ne doit pas effacer ce qui était lisible —
        // même règle qu'`AppErrorBanner`, appliquée à l'attente.
        child: _loading && _firstLoad
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                // Sans ça, une liste courte — un commerçant avec deux favoris,
                // c'est-à-dire le cas courant — ne défile pas, donc le geste de
                // rechargement ne part jamais.
                physics: const AlwaysScrollableScrollPhysics(),
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
                  Text(_t('order.fav.add.section'),
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: AppSpacing.sm),
                  TextField(
                    controller: _searchController,
                    onChanged: (_) => _search(),
                    decoration: InputDecoration(
                      hintText: _t('order.fav.search'),
                      prefixIcon: const Icon(Icons.search),
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
                    // Le nombre est interpolé, et non écrit en toutes lettres :
                    // la garde de saisie suit `driverSearchMinLength`, la
                    // consigne doit la suivre aussi. « Trois » figé sous un
                    // champ passé à quatre serait un mensonge à l'écran.
                    _t('order.fav.search.hint',
                        {'min': '${ServerRules.driverSearchMinLength}'}),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (_tooMany)
                    Padding(
                      padding:
                          const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                      child: Text(_t('order.fav.search.too_many')),
                    )
                  else if (_searched && _results.isEmpty)
                    Padding(
                      padding:
                          const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                      child: Text(_t('order.fav.search.none')),
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
                                  _t('order.fav.no_account'),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                          trailing: IconButton(
                            icon: const Icon(Icons.star_outline),
                            tooltip: _t('order.fav.add'),
                            onPressed: () => _addFavourite(state, d),
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: AppSpacing.xl),
                  Text(_t('order.fav.section'), style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: AppSpacing.sm),
                  if (state.favourites.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                      child: Text(
                        _t('order.fav.empty'),
                      ),
                    )
                  else
                    ...state.favourites.map(
                      (d) => Card(
                        child: ListTile(
                          leading:
                              Icon(Icons.star, color: context.semantic.warning),
                          title: Text(d.displayName),
                          trailing: IconButton(
                            icon: const Icon(Icons.remove_circle_outline),
                            tooltip: _t('order.fav.remove'),
                            onPressed: d.favouriteId == null
                                ? null
                                : () => state.removeFavourite(d.favouriteId!),
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: AppSpacing.xl),
                  Text(_t('order.fav.known'),
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: AppSpacing.sm),
                  if (candidates.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                      child: Text(
                        _t('order.fav.known.empty'),
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
                            tooltip: _t('order.fav.add'),
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
