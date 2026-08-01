/// Ce qu'une course attend, dit en une phrase.
///
/// ── Pourquoi composer, et non afficher `status` ───────────────────────────
///
/// Fleetbase tient **quatre faits séparés**, et aucun ne suffit seul :
///
///   `status`               où en est physiquement le colis
///   `dispatched`           la course a été diffusée un jour (fait historique)
///   `adhoc`                elle est diffusée EN CE MOMENT (état)
///   `driver_assigned_uuid` qui la fait
///
/// `Order::dispatch()` pose `dispatched` et **n'écrit jamais `status`** : ce
/// sont deux choses différentes, et la console Fleetbase les affiche elle-même
/// côte à côte. Assigner un conducteur, de son côté, n'écrit que la quatrième —
/// ni le drapeau, ni le statut.
///
/// Conséquence à l'écran, et c'est la question qui a motivé ce fichier : une
/// course confiée à quelqu'un affichait « dispatched », mot anglais qui ne dit
/// ni qu'elle est prise, ni qu'elle attend un démarrage, ni si un autre
/// transporteur peut encore la prendre. Le drapeau qui répond à cette dernière
/// question s'appelle `adhoc`, et il n'était affiché nulle part.
///
/// ── Ce n'est pas un état parallèle ────────────────────────────────────────
///
/// La règle 1 du projet interdit de **dériver un état métier** et de le servir
/// comme un champ — c'est l'erreur du drapeau `is_draft` du 30/07, qui divergeait
/// au premier échec partiel. Ici rien n'est stocké ni renvoyé : c'est un
/// **libellé d'affichage**, recalculé à chaque rendu à partir des champs qui
/// font foi. Exactement ce que fait déjà `orderStatusLabel` côté commerçant.
///
/// ── Pourquoi pas `orderStatusLabel`, justement ────────────────────────────
///
/// Parce qu'il répond à une autre question. Le commerçant demande « où en est
/// ma livraison » ; l'entreprise demande « qu'est-ce que je dois faire de cette
/// course ». « Transporteur affecté » suffit au premier et laisse le second sans
/// savoir qu'il attend un démarrage. Et `orderStatusLabel` ignore `adhoc`, donc
/// il ne peut pas distinguer « diffusée » de « retirée du pool, personne
/// dessus » — la distinction qui compte pour une entreprise.
///
/// ⚠️ Les deux devront converger : deux vocabulaires pour un même statut est
/// précisément ce que la règle 4 met en garde. Celui-ci est traduit, l'autre est
/// en français en dur (dette assumée de `docs/audit_i18n_erreurs.md`) — c'est
/// vers celui-ci que la convergence doit se faire, pas l'inverse.
library;

/// La clé de libellé décrivant l'état de [order], ou `null` si l'état n'est pas
/// reconnu.
///
/// ⚠️ **`null` plutôt qu'une phrase par défaut.** Un statut Fleetbase inconnu —
/// ajouté en amont, ou propre à une configuration de flux différente — doit
/// s'afficher **brut** plutôt que sous un libellé rassurant et faux. Afficher
/// « en cours » sur un statut qu'on ne connaît pas, c'est affirmer un fait qu'on
/// ignore, le défaut le plus répété de ce projet.
String? fleetOrderStateKey(Map<String, dynamic> order) {
  final status = order['status']?.toString();
  final hasDriver =
      order['driver_assigned_uuid'] != null || order['driver_assigned'] != null;

  // L'ordre des tests est la logique du fichier, pas une commodité : on va du
  // plus terminal au plus incertain, parce qu'un fait terminal rend tous les
  // autres sans objet. Une course livrée reste `adhoc: false` et assignée —
  // tester la diffusion d'abord dirait n'importe quoi.
  switch (status) {
    case 'canceled':
    case 'cancelled':
      return 'fleet.state.canceled';
    case 'completed':
      return 'fleet.state.completed';
    case 'started':
    case 'enroute':
    case 'driver_enroute':
      return 'fleet.state.enroute';
  }

  // Un conducteur est désigné mais le colis n'a pas bougé : c'est le cas qui
  // s'affichait « dispatched » et n'expliquait rien. Le statut vaut alors
  // `created` ou `dispatched` — les deux veulent dire la même chose ici, et
  // c'est le conducteur qui tranche.
  if (hasDriver) return 'fleet.state.awaiting_start';

  // ⚠️ `adhoc` et non `dispatched`. Le second dit « a été diffusée un jour »,
  // le premier « l'est encore ». C'est `adhoc` qui décide si quelqu'un d'autre
  // peut la prendre — et c'est aussi lui que le dispatch natif de Fleetbase
  // consulte pour relancer ses pings toutes les ~4 minutes.
  if (order['adhoc'] == true) return 'fleet.state.broadcast';

  // Plus diffusée, sans conducteur : quelqu'un l'a retirée du pool sans encore
  // désigner personne. Côté entreprise, c'est l'état qui suit une prise de
  // course, et il appelle une action.
  if (order['dispatched'] == true) return 'fleet.state.taken';

  // Ni diffusée, ni jamais dispatchée : le commerçant ne l'a pas publiée.
  if (status == 'created') return 'fleet.state.draft';

  return null;
}
