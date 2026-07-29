import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/merchant_order.dart';
import '../../services/bff_api_client.dart';
import '../../state/merchant_order_state.dart';

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
/// La liste proposée se limite aux transporteurs **ayant déjà livré pour ce
/// commerçant** — décision serveur. Exposer l'annuaire complet livrerait la
/// composition du réseau à quiconque crée un compte, et n'aurait aucune
/// utilité : on ne met en favori que quelqu'un qu'on a vu travailler.
class FavouriteDriversScreen extends StatefulWidget {
  const FavouriteDriversScreen({super.key});

  @override
  State<FavouriteDriversScreen> createState() => _FavouriteDriversScreenState();
}

class _FavouriteDriversScreenState extends State<FavouriteDriversScreen> {
  List<KnownDriver> _known = [];
  bool _loading = true;
  String? _error;

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
                padding: const EdgeInsets.all(16),
                children: [
                  if (_error != null) ...[
                    Text(_error!,
                        style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    const SizedBox(height: 16),
                  ],
                  Text('Favoris', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  if (state.favourites.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
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
                  const SizedBox(height: 24),
                  Text('Déjà intervenus pour vous',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  if (candidates.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
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
                            onPressed: () async {
                              final ok = await state.addFavourite(d);
                              if (!context.mounted) return;
                              if (!ok) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(state.errorMessage ??
                                        'Ajout impossible'),
                                    backgroundColor: Colors.red,
                                  ),
                                );
                              }
                            },
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
