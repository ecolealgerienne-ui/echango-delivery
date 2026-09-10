import 'package:flutter/material.dart';

/// Le squelette commun aux trois espaces (commerçant, transporteur, entreprise).
///
/// ── Pourquoi un widget partagé, et pas trois `Scaffold` recopiés ───────────
///
/// Règle 6 : l'homogénéité de navigation ne se maintient pas à la main. Avant,
/// le transporteur avait une barre du bas, le commerçant et l'entreprise sept
/// icônes muettes dans la barre du haut — trois modèles pour trois personas, et
/// des fonctions qu'on ne trouvait pas (« je ne cherche pas la tournée »). Ce
/// widget impose **une barre du bas libellée** (Material 3) et un corps
/// préservé d'un onglet à l'autre.
///
/// ── Ce qu'il porte, et ce qu'il ne porte pas ──────────────────────────────
///
/// - `IndexedStack` : chaque corps garde son état (position de défilement,
///   filtres) quand on change d'onglet. Une liste rechargée à chaque retour
///   serait une régression par rapport aux `TabBarView` d'avant.
/// - `persistentHeader` : un bandeau qui vit **au-dessus** de tous les onglets
///   (présence du transporteur, erreur de chargement de l'entreprise). Il ne
///   défile pas avec le corps.
/// - `floatingActionButtonFor(index)` : le FAB dépend de l'onglet — « Nouvelle »
///   n'a de sens que sur « Commandes ».
///
/// Il ne gère **pas** les routes : les destinations secondaires (encaissements,
/// dépôts…) restent des routes poussées, atteintes depuis un panneau « Plus ».
class PersonaDestination {
  final IconData icon;
  final IconData? selectedIcon;
  final String label;
  final Widget body;

  /// Pastille optionnelle sur l'icône (nombre de notifications non lues).
  final Widget? badge;

  const PersonaDestination({
    required this.icon,
    this.selectedIcon,
    required this.label,
    required this.body,
    this.badge,
  });
}

class PersonaScaffold extends StatefulWidget {
  final String title;
  final List<Widget> appBarActions;
  final Widget? persistentHeader;
  final List<PersonaDestination> destinations;
  final Widget? Function(int index)? floatingActionButtonFor;
  final int initialIndex;

  const PersonaScaffold({
    super.key,
    required this.title,
    required this.destinations,
    this.appBarActions = const [],
    this.persistentHeader,
    this.floatingActionButtonFor,
    this.initialIndex = 0,
  }) : assert(destinations.length >= 2 && destinations.length <= 5,
            'Material 3 NavigationBar : 2 à 5 destinations');

  @override
  State<PersonaScaffold> createState() => _PersonaScaffoldState();
}

class _PersonaScaffoldState extends State<PersonaScaffold> {
  late int _index = widget.initialIndex.clamp(0, widget.destinations.length - 1);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: widget.appBarActions,
      ),
      body: Column(
        children: [
          if (widget.persistentHeader != null) widget.persistentHeader!,
          Expanded(
            child: IndexedStack(
              index: _index,
              children: [
                for (final d in widget.destinations) d.body,
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: widget.floatingActionButtonFor?.call(_index),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        // Les libellés français sont longs ; ne montrer que celui de l'onglet
        // actif garde la barre lisible sur un écran étroit.
        labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
        destinations: [
          for (final d in widget.destinations)
            NavigationDestination(
              icon: d.badge == null
                  ? Icon(d.icon)
                  : Badge(label: d.badge, child: Icon(d.icon)),
              selectedIcon:
                  d.selectedIcon == null ? null : Icon(d.selectedIcon),
              label: d.label,
            ),
        ],
      ),
    );
  }
}
