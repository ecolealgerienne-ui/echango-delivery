import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'driver_picker.dart';
import 'memberships_tab.dart';
import '../../i18n/fleet_strings.dart';
import '../../models/fleet_order_state.dart';
import '../../models/vehicle_type.dart';
import '../../state/auth_state.dart';
import '../../state/fleet_state.dart';
import '../../state/locale_state.dart';
import '../../widgets/app_snack_bar.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_banner.dart';
import '../../widgets/language_selector.dart';
import '../../widgets/load_more_footer.dart';
import '../../theme/app_buttons.dart';
import '../../theme/app_semantic_colors.dart';
import '../../theme/app_spacing.dart';
import '../../utils/dates.dart';

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
  late final TabController _tabs = TabController(length: 4, vsync: this);

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
          // ⚠️ La route `GET /flotte/drivers/positions` existait depuis le
          // 28/07 et n'était appelée nulle part — alors que la vision produit
          // définit ce persona par « commandes entrantes, assignation à un
          // conducteur disponible, **position des conducteurs** ». Le tiers
          // manquant était côté app, pas côté serveur.
          IconButton(
            icon: const Icon(Icons.map_outlined),
            tooltip: t('fleet.map.open'),
            onPressed: () => context.push('/flotte/carte'),
          ),
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
      ),
      // ⚠️ Le chargement ne remplace plus **tout** le corps : les onglets
      // restent en place et seul le contenu attend. Sinon ils apparaissaient
      // une fois la première réponse reçue, et la page sautait sous le doigt —
      // un défaut que le déplacement depuis l'AppBar aurait introduit, la barre
      // y étant affichée en permanence.
      body: Column(
              children: [
                // ⚠️ **Les onglets sont sur la PAGE, pas dans l'AppBar.**
                //
                // Ils y étaient, et c'était illisible : le thème des onglets
                // pose un libellé bleu sur fond clair (`tabBarTheme`), tandis
                // que l'AppBar est bleue — donc libellé bleu sur bleu pour
                // l'onglet actif, indicateur bleu sur bleu, et gris délavé pour
                // les autres. Un seul thème ne peut pas servir les deux fonds.
                //
                // Les deux autres profils — tableau de bord transporteur, liste
                // commerçant — posaient déjà leurs onglets sur la page. Celui-ci
                // était le seul à faire autrement, et le seul illisible.
                TabBar(
                  controller: _tabs,
                  isScrollable: true,
                  tabs: [
                    Tab(text: t('fleet.tab.orders')),
                    Tab(text: t('fleet.tab.opportunities')),
                    Tab(text: t('fleet.tab.drivers')),
                    Tab(text: t('fleet.tab.memberships')),
                  ],
                ),
                // ⚠️ Sans ce bandeau, une flotte inactive, un jeton expiré ou
                // un BFF injoignable produisaient l'écran « Aucune course
                // confiée à votre entreprise » — un message qui affirme un
                // fait faux. Le même défaut a été corrigé deux fois ailleurs.
                if (state.errorMessage != null)
                  AppErrorBanner(
                    message: state.errorMessage!,
                    onRetry: () => context.read<FleetState>().load(),
                    retryLabel: t('fleet.retry'),
                  ),
                Expanded(
                  child: state.isLoading && state.orders.isEmpty
                      ? Center(child: Text(t('fleet.loading')))
                      : RefreshIndicator(
                          onRefresh: () => context.read<FleetState>().load(),
                          child: TabBarView(
                            controller: _tabs,
                            children: [
                              _OrdersTab(t: t),
                              _OpportunitiesTab(t: t),
                              _DriversTab(t: t),
                              MembershipsTab(
                                t: t,
                                onCreateDriver: () => _addDriver(context, t),
                              ),
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
class _OrdersTab extends StatelessWidget {
  const _OrdersTab({required this.t});

  final _Translate t;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<FleetState>();
    if (state.orders.isEmpty) {
      return AppEmptyState(
        title: t('fleet.orders.empty'),
        hint: t('fleet.orders.empty.hint'),
      );
    }

    // Le pied de liste n'apparaît que s'il reste vraiment quelque chose : le
    // total vient du serveur, pas d'une supposition sur la taille de page.
    final showMore = state.hasMoreOrders;

    return ListView.separated(
      itemCount: state.orders.length + (showMore ? 1 : 0),
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        if (i == state.orders.length) {
          return AppLoadMore(
            isLoading: state.isLoadingMoreOrders,
            label: t('fleet.orders.more'),
            onPressed: state.loadMoreOrders,
          );
        }

        final order = state.orders[i];
        final meta = order['meta'] as Map<String, dynamic>? ?? const {};
        final hasDriver = order['driver_assigned_uuid'] != null;

        return ListTile(
          title: Text(_dropoffLabel(order)),
          // ⚠️ Une seule ligne d'état, composée, à la place de deux.
          //
          // L'ancienne version affichait « Statut : dispatched » puis
          // « Conducteur » ou « Aucun conducteur désigné » — deux lignes dont
          // la première était en anglais et dont la seconde répétait à moitié
          // la première. Le libellé composé dit la même chose en français, et
          // ajoute ce qu'aucune des deux ne disait : que la course attend un
          // démarrage, ou qu'elle est encore réclamable par quelqu'un d'autre.
          subtitle: Text('${_stateLabel(order, t)}${_amount(meta, t)}'),
          isThreeLine: true,
          // La ligne mène à la fiche. Sans elle, l'entreprise ne voyait jamais
          // ni l'adresse, ni les instructions, ni le contact d'une course
          // pourtant à elle — elle ne pouvait rien dire à son conducteur.
          // ⚠️ Pas de repli `?? ''` : `/flotte/commandes/` ne correspond à
          // aucune route (le segment `:id` exige un caractère) et go_router
          // afficherait son écran d'erreur. Ne rien faire est le bon geste
          // quand il n'y a nulle part où aller.
          onTap: _openable(order) ? () => context.push('/flotte/commandes/${order['uuid']}') : null,
          // ⚠️ **Un `FilledButton`, comme dans l'onglet d'à côté.** C'était un
          // `TextButton` : l'action principale de la ligne — celle sans
          // laquelle la course ne partira jamais — se lisait comme un lien,
          // pendant que « Prendre cette course » s'affichait en bouton plein à
          // un coup d'onglet d'écart. Même nature d'action, deux niveaux de
          // visibilité, dans le même écran (voir `theme/app_buttons.dart`).
          //
          // ⚠️ Libellé **court** et style de ligne : `ListTile` ne contraint
          // pas son `trailing`, donc « Désigner un conducteur » avec le
          // rembourrage de page déborderait sur un écran étroit. Le verbe seul
          // suffit ici — la ligne dit de quoi il s'agit —, et la formulation
          // entière reste sur la fiche, où il y a la place.
          trailing: hasDriver
              ? null
              : FilledButton(
                  style: AppButtonStyles.rowAction,
                  onPressed: () => _pickDriver(context, order, t),
                  child: Text(t('fleet.orders.assign.short')),
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
    // `t` ne suffit pas ici : les faits d'une opportunité contiennent une heure
    // et un nom de véhicule, qui se formatent avec la locale et non avec une
    // clé.
    final locale = context.watch<LocaleState>().locale;
    if (state.opportunities.isEmpty) {
      return AppEmptyState(
        title: t('fleet.opportunities.empty'),
        hint: t('fleet.opportunities.empty.hint'),
      );
    }

    final showMore = state.hasMoreOpportunities;
    // La règle du masquage vaut pour toute la liste : elle se dit **une fois**,
    // en tête. Répétée sur chaque ligne, elle occupait la place des chiffres
    // sur lesquels on décide — et cinq fois la même phrase se cesse d'être lue
    // dès la deuxième.
    final masked = state.opportunities.any((o) => o['redacted'] == true);

    return Column(
      children: [
        if (masked)
          Container(
            width: double.infinity,
            // `secondaryContainer`, et c'est désormais un choix et non un
            // repli. ⚠️ La raison inscrite ici jusqu'au 01/08/2026 était fausse :
            // elle écartait `surfaceContainerHighest` (Flutter 3.22) au motif
            // que le pubspec déclarait `>=3.20.0`, sans voir que la ligne `sdk:`
            // du même fichier exigeait déjà Dart 3.5, donc Flutter >= 3.24.
            // L'API était disponible depuis le début ; la borne, elle, nommait
            // une version jamais sortie en stable. Borne corrigée, et la
            // couleur laissée telle quelle — la changer déplacerait des pixels
            // sans que personne ait regardé l'écran.
            color: Theme.of(context).colorScheme.secondaryContainer,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Text(
              t('fleet.opportunities.masked'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        Expanded(
          child: ListView.separated(
      itemCount: state.opportunities.length + (showMore ? 1 : 0),
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        if (i == state.opportunities.length) {
          return AppLoadMore(
            isLoading: state.isLoadingMoreOpportunities,
            label: t('fleet.opportunities.more'),
            onPressed: state.loadMoreOpportunities,
          );
        }

        final order = state.opportunities[i];
        final meta = order['meta'] as Map<String, dynamic>? ?? const {};
        final uuid = order['uuid'] as String? ?? '';
        final claiming = state.claimingOrderId == uuid;

        // ── Ce qui permet de décider, et rien d'autre ──────────────────────
        //
        // ⚠️ La ligne ne portait que la phrase de masquage, **identique sur
        // toutes les lignes** — cinq fois le même texte, et pas un chiffre. La
        // question posée le 31/07 (« sur quels critères je dois accepter cette
        // course ? ») restait donc sans réponse dans la liste, alors que le
        // serveur sert tout ce qu'il faut depuis le début.
        //
        // La phrase est remontée **une fois** en tête de liste : elle décrit la
        // règle, pas la course, et la répéter mangeait la place des chiffres.
        return ListTile(
          title: Text(_journey(order), maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(_opportunityFacts(order, meta, t, locale)),
          isThreeLine: true,
          // ⚠️ La question du 31/07 était « sur quels critères je dois accepter
          // cette course ? ». La liste ne pouvait pas y répondre seule : le
          // détour, l'accès, l'heure prévue tiennent dans la fiche. Le bouton
          // « Prendre » reste sur la ligne pour ceux qui n'en ont pas besoin.
          onTap: uuid.isEmpty ? null : () => context.push('/flotte/opportunites/$uuid'),
          // Même style que l'onglet d'à côté, et pour la même raison : c'est
          // l'action principale d'une ligne de liste, pas d'une page.
          trailing: FilledButton(
            style: AppButtonStyles.rowAction,
            onPressed: claiming ? null : () => _claim(context, uuid, t),
            // Pendant la prise, un indicateur plutôt que « Prise en cours… » :
            // le texte long change la largeur du bouton au moment précis où la
            // ligne est en train de disparaître, et c'est ce genre de saut qui
            // fait toucher la ligne d'à côté.
            child: claiming
                ? const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(t('fleet.opportunities.take.short')),
          ),
        );
      },
          ),
        ),
      ],
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

    // ⚠️ Défaut réel corrigé en extrayant le composant, pas un simple
    // remplacement de mise en page : `FleetState.load()` avale l'échec de
    // `getFleetDrivers()` en rendant une liste vide, donc cet écran affirmait
    // « Aucun conducteur rattaché à votre entreprise » à une entreprise dont
    // le BFF était injoignable. `driversUnavailable` existait et n'était lu
    // que par `driver_picker` — l'écran, lui, ne posait pas la question.
    if (state.driversUnavailable) {
      return Scaffold(
        body: AppEmptyState.unavailable(
          title: t('fleet.drivers.unavailable'),
          hint: t('fleet.drivers.unavailable.hint'),
          onRetry: () => context.read<FleetState>().load(),
        ),
        floatingActionButton: add,
      );
    }

    if (state.drivers.isEmpty) {
      return Scaffold(
        body: AppEmptyState(
          title: t('fleet.drivers.empty'),
          hint: t('fleet.drivers.add'),
        ),
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
            color: online
                ? context.semantic.success
                : Theme.of(context).colorScheme.outline,
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
///
/// ⚠️ **Le serveur exige au moins un email ou un téléphone.** Sans identifiant,
/// il ne peut ni détecter un doublon ni envoyer l'invitation : le conducteur
/// serait créé pour ne jamais servir. Le formulaire le vérifie avant l'appel
/// pour dire pourquoi plutôt que d'attendre un refus.
Future<void> _addDriver(BuildContext context, _Translate t) async {
  final input = await showDialog<_NewDriver>(
    context: context,
    builder: (_) => _AddDriverDialog(t: t),
  );

  if (input == null || !context.mounted) return;

  final error = await context
      .read<FleetState>()
      .addDriver(name: input.name, email: input.email, phone: input.phone);

  if (!context.mounted || error == null) return;
  showAppError(context, error);
}

/// Ce que le formulaire a saisi. Rendu par valeur plutôt que lu depuis des
/// contrôleurs après coup — ceux-ci n'existent plus à ce moment-là.
class _NewDriver {
  const _NewDriver({required this.name, required this.email, required this.phone});

  final String name;
  final String email;
  final String phone;
}

/// Le formulaire de création, **avec ses propres contrôleurs**.
///
/// ── Pourquoi un widget, et non trois contrôleurs dans une fonction ────────
///
/// La version précédente créait les `TextEditingController` dans `_addDriver`,
/// attendait `showDialog`, puis les libérait juste après. Or `showDialog` rend
/// la main dès le `Navigator.pop` — **l'animation de fermeture, elle, continue**,
/// et reconstruit les `TextField` avec des contrôleurs déjà libérés :
///
///     A TextEditingController was used after being disposed.
///
/// Suivi d'un `_dependents.isEmpty is not true` et d'un « dirty widget in the
/// wrong build scope » — la même faute qui cascade. `flutter analyze` ne voit
/// rien : c'est une règle de cycle de vie, pas de typage, et elle ne se déclenche
/// qu'à l'écran.
///
/// La règle qui évite d'y revenir : **un contrôleur appartient au `State` du
/// widget qui l'utilise**, et meurt avec lui. Ici le `State` du dialogue vit
/// aussi longtemps que son animation.
class _AddDriverDialog extends StatefulWidget {
  const _AddDriverDialog({required this.t});

  final _Translate t;

  @override
  State<_AddDriverDialog> createState() => _AddDriverDialogState();
}

class _AddDriverDialogState extends State<_AddDriverDialog> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();

  String? _problem;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    final email = _email.text.trim();
    final phone = _phone.text.trim();

    if (name.isEmpty) {
      setState(() => _problem = widget.t('fleet.drivers.name_required'));
      return;
    }

    // La même règle que le serveur, dite avant l'appel plutôt qu'après le refus.
    if (email.isEmpty && phone.isEmpty) {
      setState(() => _problem = widget.t('fleet.drivers.contact_required'));
      return;
    }

    Navigator.of(context).pop(_NewDriver(name: name, email: email, phone: phone));
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;

    return AlertDialog(
      title: Text(t('fleet.drivers.add')),
      // ⚠️ Défilant : sans ça, le clavier ouvert réduisait la hauteur
      // disponible et la colonne débordait de dizaines de milliers de pixels
      // (« A RenderFlex overflowed by 99392 pixels on the bottom »).
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(labelText: t('fleet.drivers.name')),
            ),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(labelText: t('fleet.drivers.email')),
            ),
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(labelText: t('fleet.drivers.phone')),
            ),
            if (_problem != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text(
                _problem!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t('fleet.cancel')),
        ),
        FilledButton(onPressed: _submit, child: Text(t('fleet.confirm'))),
      ],
    );
  }
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
/// Le TRAJET, et non la destination seule.
///
/// ── Pourquoi le trajet ────────────────────────────────────────────────────
///
/// Une entreprise ne décide pas sur une adresse d'arrivée : elle décide sur un
/// **détour**. « Belcourt → Hydra » se juge d'un coup d'œil, « Hydra » seul ne
/// se juge pas — il manque d'où l'on part.
///
/// ⚠️ Le repli sur `public_id` a été **retiré** : c'est lui qui affichait
/// `order_1sn4fzn6e2` en titre, quatre lignes sur cinq. Un identifiant
/// technique n'aide personne à décider ; l'absence, dite en toutes lettres,
/// au moins ne trompe pas.
String _journey(Map<String, dynamic> order) {
  final payload = order['payload'] as Map<String, dynamic>?;
  final from = _placeLabel(payload?['pickup'] as Map<String, dynamic>?);
  final to = _placeLabel(payload?['dropoff'] as Map<String, dynamic>?);

  if (from != null && to != null) return '$from → $to';
  return to ?? from ?? '—';
}

/// Le nom court d'un lieu : quartier, commune, ou ce que l'adresse en dit.
///
/// ⚠️ **`name` n'est pas lu**, et c'est délibéré : sur un lieu de livraison il
/// porte le nom du destinataire (`createPlace(dto.dropoffLocationName, …)`),
/// que la course non réclamée masque justement. Le lire ici rouvrirait par
/// l'affichage ce que la projection ferme côté serveur.
String? _placeLabel(Map<String, dynamic>? place) {
  for (final candidate in [
    place?['neighborhood'],
    place?['city'],
    place?['address'],
  ]) {
    if (candidate is String && candidate.trim().isNotEmpty) return candidate.trim();
  }
  return null;
}

/// Ce qui décide : rémunération, encaissement, distance, échéance, véhicule.
///
/// Deux lignes au plus, l'argent d'abord. Chaque élément n'apparaît que s'il
/// est connu — une ligne qui annoncerait « 0 km » ou « — DZD » ferait douter du
/// chiffre voisin, qui est juste.
String _opportunityFacts(
  Map<String, dynamic> order,
  Map<String, dynamic> meta,
  _Translate t,
  Locale locale,
) {
  final money = <String>[];
  final price = meta['price'];
  final cod = meta['cod_amount'];
  final currency = meta['currency'] ?? meta['cod_currency'] ?? '';
  if (price is num && price > 0) {
    money.add('${t('fleet.orders.price')} : ${price.toStringAsFixed(0)} $currency'.trim());
  }
  // ⚠️ Servi même quand il vaut zéro ? Non : une course sans encaissement ne
  // doit pas afficher « à encaisser : 0 », qui se lit comme une anomalie. Son
  // absence dit déjà qu'il n'y a rien à percevoir.
  if (cod is num && cod > 0) {
    money.add('${t('fleet.orders.cod')} : ${cod.toStringAsFixed(0)} $currency'.trim());
  }

  final facts = <String>[];
  final distance = _distanceLabel(order['distance'], t);
  if (distance != null) facts.add(distance);
  final scheduled = _scheduledLabel(order['scheduled_at'], t, locale);
  if (scheduled != null) facts.add(scheduled);
  final vehicle = meta['vehicle_type'];
  // ⚠️ Le **code** brut était affiché — « moto », « utilitaire » —, c'est-à-dire
  // la valeur que le serveur stocke, au milieu d'une ligne par ailleurs
  // traduite. Trouvé en faisant passer la locale ici, pas en relisant.
  if (vehicle is String && vehicle.trim().isNotEmpty) {
    facts.add(vehicleLabel(vehicle.trim(), locale));
  }

  return [
    if (money.isNotEmpty) money.join('  ·  '),
    if (facts.isNotEmpty) facts.join('  ·  '),
    if (money.isEmpty && facts.isEmpty) t('fleet.opportunities.no_detail'),
  ].join('\n');
}

/// La longueur du TRAJET, pas une distance depuis le lecteur.
///
/// ⚠️ Le libellé le dit (`fleet.orders.trip_distance`), et ce n'est pas un
/// détail : « 12 km » sur une ligne de liste se lit spontanément comme « à 12 km
/// de moi ». Le serveur ne sait pas où se trouve l'entreprise, et ne peut donc
/// rien dire de tel — laisser l'ambiguïté ferait refuser des courses proches et
/// accepter des courses lointaines.
String? _distanceLabel(Object? metres, _Translate t) {
  if (metres is! num || metres <= 0) return null;
  final value = metres >= 1000
      ? '${(metres / 1000).toStringAsFixed(1)} ${t('fleet.unit.km')}'
      : '${metres.round()} ${t('fleet.unit.m')}';
  return '${t('fleet.orders.trip_distance')} $value';
}

/// L'échéance, en clair.
///
/// ⚠️ Rien du tout quand la course est immédiate : afficher « dès que possible »
/// sur chaque ligne remettrait exactement le bruit qu'on vient d'enlever. C'est
/// la mention d'une heure qui est une information ; son absence est la norme.
String? _scheduledLabel(Object? raw, _Translate t, Locale locale) {
  if (raw is! String || raw.trim().isEmpty) return null;
  final at = DateTime.tryParse(raw);
  if (at == null) return null;
  return '${t('fleet.orders.scheduled')} ${formatDayTime(at, locale)}';
}

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

/// L'état de la course, en une phrase.
///
/// ⚠️ Retombe sur le **statut brut** quand l'état n'est pas reconnu, plutôt que
/// sur une phrase par défaut : afficher « en cours » sur un statut qu'on ignore,
/// c'est affirmer un fait qu'on n'a pas.
String _stateLabel(Map<String, dynamic> order, _Translate t) {
  final key = fleetOrderStateKey(order);
  if (key != null) return t(key);
  return '${t('fleet.orders.status')} : ${order['status'] ?? '—'}';
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

  showAppOutcome(context, error, t('fleet.opportunities.taken'));
}

/// Où mène cette ligne, si elle mène quelque part.
bool _openable(Map<String, dynamic> order) {
  final uuid = order['uuid'];
  return uuid is String && uuid.isNotEmpty;
}

Future<void> _pickDriver(
  BuildContext context,
  Map<String, dynamic> order,
  _Translate t,
) async {
  final result = await pickAndAssignDriver(context, order['uuid'] as String? ?? '', t);
  if (!context.mounted) return;
  if (result.outcome != DriverAssignment.failed) return;
  showAppError(context, result.message ?? t('fleet.detail.not_found'));
}
