/// Outillage commun aux parcours joués sur l'appareil.
///
/// ── Pourquoi rien n'est cherché par son libellé ───────────────────────────
///
/// Les widgets sont désignés par leur **icône**, leur **type**, leur **rang
/// dans une barre d'onglets**, ou une **donnée que le décor a posée** — jamais
/// par un texte traduit. Une recherche par libellé lierait le test à la langue
/// de l'émulateur : il passerait au vert ici et échouerait sur un téléphone en
/// arabe, pour une raison sans rapport avec le défaut.
library;

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echango_delivery/screens/auth/login_screen.dart';
import 'package:echango_delivery/state/auth_state.dart' show UserRole;
import 'package:echango_delivery/widgets/error_banner.dart';
import 'package:echango_delivery/widgets/notice.dart';

// ── Identifiants, posés par scripts/provision-app-parcours.sh ───────────────
//
// Aucune valeur par défaut sur les emails, et c'est délibéré : un test qui se
// rabattrait sur un compte imaginaire échouerait à la connexion en accusant
// l'écran de connexion. Absents, on le dit tout de suite et on nomme le script.

const String merchantEmail = String.fromEnvironment('TEST_MERCHANT_EMAIL');
const String fleetEmail = String.fromEnvironment('TEST_FLEET_EMAIL');
const String driverEmail = String.fromEnvironment('TEST_DRIVER_EMAIL');
const String password =
    String.fromEnvironment('TEST_PASSWORD', defaultValue: 'motdepasse123');
const String pickupName =
    String.fromEnvironment('TEST_PICKUP_NAME', defaultValue: 'Dépôt Alger-Centre');
const String dropoffName =
    String.fromEnvironment('TEST_DROPOFF_NAME', defaultValue: 'Client Hydra');

/// Vérifie que le décor a été posé, et nomme le script sinon.
void requireCredentials(Map<String, String> needed) {
  final missing = needed.entries.where((e) => e.value.isEmpty).map((e) => e.key);
  if (missing.isNotEmpty) {
    fail(
      '${missing.join(', ')} absent(s).\n'
      'Poser le décor d’abord :  ./scripts/provision-app-parcours.sh [conducteur]\n'
      'puis relancer avec les --dart-define qu’il imprime.',
    );
  }
}

/// Remet l'appareil dans l'état « aucune session ».
///
/// ⚠️ **Sans ça, le test lit l'état laissé par quelqu'un d'autre (constaté le
/// 02/08/2026).** `flutter drive` installe **par-dessus** l'application déjà
/// présente : préférences et stockage sécurisé survivent. L'appareil portait la
/// session d'un lancement manuel, l'application l'a restaurée, et elle est allée
/// droit sur un écran d'accueil sans jamais montrer la connexion — le test a
/// alors accusé l'écran de connexion de n'avoir aucun champ.
///
/// À appeler avant **chaque** parcours, pas une fois pour toutes : un parcours
/// qui se connecte **laisse** une session au suivant.
Future<void> resetDevice() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.clear();
  await const FlutterSecureStorage().deleteAll();
}

/// Les trois accueils, reconnus par ce qu'ils portent d'unique.
enum Home {
  /// Liste des courses du commerçant : seul écran à porter un bouton flottant.
  merchant,

  /// Tableau de bord transporteur : trois onglets (opportunités, en cours,
  /// historique).
  driver,

  /// Accueil entreprise : quatre onglets (courses, opportunités, conducteurs,
  /// adhésions).
  fleet,
}

/// Le repère qui prouve qu'on est arrivé sur cet accueil-là.
///
/// ⚠️ Le nombre d'onglets distingue transporteur et entreprise. C'est un repère
/// **fragile mais honnête** : si un onglet est ajouté, le test échoue en le
/// disant, il ne pilote pas le mauvais écran. Le compte est donc affirmé, pas
/// seulement utilisé pour choisir.
Finder homeAnchor(Home home) => switch (home) {
      Home.merchant => find.byType(FloatingActionButton),
      Home.driver || Home.fleet => find.byType(Tab),
    };

int expectedTabs(Home home) => switch (home) {
      Home.merchant => 0,
      Home.driver => 3,
      Home.fleet => 4,
    };

/// Se connecte depuis un démarrage neuf et attend l'accueil du persona.
Future<void> loginAs(
  WidgetTester tester, {
  required String email,
  required Home home,
}) async {
  // Le démarrage traverse un splash qui interroge le stockage sécurisé et le
  // BFF : on attend l'écran, on ne le suppose pas arrivé.
  await pumpUntil(tester, find.byType(FilledButton), reason: 'écran de connexion');

  // ⚠️ **Les champs sont cherchés SOUS l'écran visé, jamais dans tout l'arbre.**
  // Pendant une transition de route, l'écran qu'on quitte est encore monté et
  // ses champs comptent dans `find.byType(TextField)`.
  final fields = find.descendant(
      of: find.byType(LoginScreen), matching: find.byType(TextField));
  expect(fields, findsNWidgets(2),
      reason: 'l’écran de connexion porte exactement deux champs');

  await tester.enterText(fields.at(0), email);
  await tester.enterText(fields.at(1), password);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pump();

  final submit = find.descendant(
      of: find.byType(LoginScreen), matching: find.byType(FilledButton));
  await tester.tap(submit);

  // ⚠️ **Le plafond de connexion est de CINQ par minute, et cette suite en
  // demande quatre — une par persona (constaté le 02/08/2026).**
  //
  // Ajoutées aux connexions du script de décor, elles franchissent la limite :
  // le serveur répond 429, l'écran affiche son bandeau d'erreur, et le test
  // échouait en accusant « compte non activé ou BFF injoignable » — trois
  // hypothèses fausses pour une cause qui n'a rien à voir.
  //
  // Le plafond est une garde de production délibérée : ce n'est pas au produit
  // de céder, c'est à la suite d'attendre. On laisse donc passer la fenêtre et
  // on réessaie **une** fois — au-delà, l'échec est réel et doit se voir.
  if (!await _reached(tester, homeAnchor(home), const Duration(seconds: 12))) {
    if (find.byType(AppErrorBanner).evaluate().isNotEmpty) {
      // La fenêtre du plafond est d'une minute ; on la laisse s'écouler en
      // pompant, pour que l'application reste vivante pendant l'attente.
      await _idle(tester, const Duration(seconds: 65));
      await tester.tap(submit);
    }
  }

  await pumpUntil(tester, homeAnchor(home),
      reason: 'accueil ${home.name} pour $email',
      onTimeout: 'la connexion n’a pas abouti — compte non activé, mauvais mot '
          'de passe, plafond de cinq connexions par minute franchi deux fois, '
          'ou BFF injoignable depuis l’appareil (ApiConfig.bffBaseUrl)');

  if (expectedTabs(home) > 0) {
    expect(find.byType(Tab), findsNWidgets(expectedTabs(home)),
        reason: 'l’accueil ${home.name} doit porter ${expectedTabs(home)} onglets — '
            'un compte d’un autre persona ouvrirait un écran différent');
  }
}

/// Bascule sur l'onglet de rang [index] de la barre visible.
Future<void> openTab(WidgetTester tester, int index) async {
  final tabs = find.byType(Tab);
  expect(tabs.evaluate().length, greaterThan(index),
      reason: 'onglet $index demandé, ${tabs.evaluate().length} présents');
  await tester.tap(tabs.at(index));
  await tester.pump(const Duration(milliseconds: 600));
}

// ── Attentes ────────────────────────────────────────────────────────────────

/// Pompe jusqu'à ce que `finder` matche, ou échoue en disant quoi regarder.
///
/// ⚠️ **`pumpAndSettle` ne convient pas ici, et c'est le piège n°1 du pilotage
/// d'application.** Il pompe jusqu'à ce qu'il n'y ait plus d'animation en
/// cours — or un `CircularProgressIndicator` tourne indéfiniment. Tout écran
/// qui charge quelque chose le fait donc expirer au bout de dix minutes, sur un
/// message qui parle d'animations et non du chargement qui n'aboutit pas.
///
/// On attend donc une **condition**, pas un repos. Et le message d'échec dit ce
/// qu'on attendait : « timeout » tout court oblige à rejouer le parcours à la
/// main pour savoir où il s'est arrêté.
Future<void> pumpUntil(
  WidgetTester tester,
  Finder finder, {
  required String reason,
  String? onTimeout,
  Duration timeout = const Duration(seconds: 40),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 120));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('Jamais atteint : $reason'
      '${onTimeout == null ? '' : '\n  → $onTimeout'}'
      '\n  Écran au moment de l’abandon : ${whatIsOnScreen()}');
}

/// Pompe pendant [d] sans rien attendre — laisse le temps s'écouler côté
/// application, ce qu'un `Future.delayed` nu ne fait pas : sans battements,
/// l'interface ne se reconstruit pas et les minuteries ne progressent pas.
Future<void> _idle(WidgetTester tester, Duration d) async {
  final until = DateTime.now().add(d);
  while (DateTime.now().isBefore(until)) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// `finder` apparaît-il avant [timeout] ? Rend un booléen au lieu d'échouer —
/// pour les cas où l'absence est une branche, pas un défaut.
Future<bool> _reached(
    WidgetTester tester, Finder finder, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 120));
    if (finder.evaluate().isNotEmpty) return true;
  }
  return false;
}

/// Attend une **condition quelconque**, pas la présence d'un widget.
///
/// ⚠️ Écrite parce que la première version exprimait « il reste une opportunité
/// de moins » par un `find.byWidgetPredicate` dont le prédicat ignorait son
/// argument : il matchait alors **tous** les widgets de l'arbre dès que la
/// condition tenait, et aucun quand l'arbre était vide. Ça marchait par
/// accident, pour une raison qui n'a rien à voir avec ce qu'on voulait dire.
Future<void> pumpUntilTrue(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
  String? onTimeout,
  Duration timeout = const Duration(seconds: 40),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 120));
    if (condition()) return;
  }
  fail('Jamais atteint : $reason'
      '${onTimeout == null ? '' : '\n  → $onTimeout'}'
      '\n  Écran au moment de l’abandon : ${whatIsOnScreen()}');
}

/// Le pendant de [pumpUntil] pour une **disparition**.
///
/// Écrit comme une fonction et non comme un finder inversé : un `Finder` qui
/// rend un élément fabriqué pour signifier « rien » est un mensonge que la
/// couche d'assertion finit par déballer.
Future<void> pumpUntilGone(
  WidgetTester tester,
  Finder finder, {
  required String reason,
  String? onTimeout,
  Duration timeout = const Duration(seconds: 40),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 120));
    if (finder.evaluate().isEmpty) return;
  }
  fail('Jamais atteint : $reason'
      '${onTimeout == null ? '' : '\n  → $onTimeout'}'
      '\n  Écran au moment de l’abandon : ${whatIsOnScreen()}');
}

// ── Gestes ──────────────────────────────────────────────────────────────────

/// Amène le widget dans la fenêtre **avant** de taper dessus.
///
/// ⚠️ `tester.tap` frappe les coordonnées du centre du widget, même quand ce
/// centre est **hors de l'écran** : le formulaire de course défile, son bouton
/// d'enregistrement vit tout en bas, et le tap partait donc sur ce qui se
/// trouvait à ces coordonnées-là. Aucune exception — le test attendait ensuite
/// une navigation qui n'avait aucune raison d'arriver.
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 300));
}

/// Tape, puis guette le message affiché pendant les secondes où il l'est.
///
/// ⚠️ **Un `SnackBar` s'efface au bout de quelques secondes** — une attente de
/// quarante secondes ne le voit donc jamais, et l'échec se présente comme
/// « rien ne s'est passé » alors que l'application a peut-être dit exactement
/// pourquoi.
///
/// ⚠️ Et il faut **attendre la disparition du précédent avant d'agir**, sinon
/// on lit l'étape d'avant : la publication a une fois rapporté « Brouillon
/// enregistré… », le message de l'enregistrement. Un diagnostic qui cite le
/// mauvais message est pire que pas de diagnostic — il fait chercher un défaut
/// là où il n'y en a pas.
Future<String?> tapAndCatchOutcome(WidgetTester tester, Finder finder) async {
  final clear = DateTime.now().add(const Duration(seconds: 8));
  while (DateTime.now().isBefore(clear) &&
      find.byType(SnackBar).evaluate().isNotEmpty) {
    await tester.pump(const Duration(milliseconds: 200));
  }

  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(finder);

  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    final bar = find.byType(SnackBar);
    if (bar.evaluate().isEmpty) continue;
    final texts = find
        .descendant(of: bar, matching: find.byType(Text))
        .evaluate()
        .map((e) => (e.widget as Text).data)
        .whereType<String>()
        .toList();
    if (texts.isNotEmpty) return texts.join(' — ');
  }
  return null;
}

// ── Diagnostic ──────────────────────────────────────────────────────────────

/// Nomme l'écran visible, pour qu'un échec d'attente n'oblige pas à enquêter.
///
/// ⚠️ Écrit après coup, et c'est l'enseignement du 02/08/2026 : « jamais
/// atteint : écran de connexion » a coûté une demi-heure d'hypothèses alors que
/// la réponse — « l'application est sur un écran d'accueil, une session traînait
/// » — tenait en un repère. Une absence qui ne dit pas ce qu'il y avait à la
/// place laisse chercher au mauvais endroit.
String whatIsOnScreen() {
  final marks = <String, Finder>{
    'splash (chargement)': find.byType(CircularProgressIndicator),
    'connexion': find.byType(LoginScreen),
    'inscription': find.byType(SegmentedButton<UserRole>),
    'accueil commerçant': find.byType(FloatingActionButton),
    'formulaire de course': find.byIcon(Icons.save_outlined),
    'fiche commerçant': find.byIcon(Icons.publish_outlined),
    'bandeau': find.byType(AppNotice),
  };
  final seen = marks.entries
      .where((e) => e.value.evaluate().isNotEmpty)
      .map((e) => e.key)
      .toList();
  final tabs = find.byType(Tab).evaluate().length;
  if (tabs > 0) seen.add('$tabs onglets');
  final fields = find.byType(TextField).evaluate().length;
  return seen.isEmpty
      ? 'aucun repère connu ($fields champs de saisie)'
      : '${seen.join(' + ')} ($fields champs de saisie)';
}

/// Les textes visibles, pour qu'un « introuvable » dise ce qui était là.
String visibleTexts([int limit = 30]) {
  final seen = find
      .byType(Text)
      .evaluate()
      .map((e) => (e.widget as Text).data)
      .whereType<String>()
      .where((s) => s.trim().isNotEmpty)
      .take(limit)
      .toList();
  return seen.isEmpty ? 'aucun' : seen.join(' | ');
}
