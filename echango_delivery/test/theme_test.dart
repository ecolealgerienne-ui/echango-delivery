import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echango_delivery/theme/app_semantic_colors.dart';
import 'package:echango_delivery/theme/app_spacing.dart';
import 'package:echango_delivery/theme/app_theme.dart';

/// Ce que le système de design promet, vérifié **en le faisant tourner**.
///
/// ── Pourquoi ce fichier existe ────────────────────────────────────────────
///
/// Le dépôt a payé deux fois le même défaut : le thème sombre n'avait **aucun
/// style de bouton**, puis **aucun thème d'onglets**, et la couleur de marque
/// était écrite trois fois. Rien de tout cela ne se voit en relisant un thème —
/// il faut les mettre côte à côte, ce que personne ne fait (règle 5, § « Deux
/// thèmes sont deux copies, et personne ne les compare »).
///
/// Ces tests font exactement ça : ils **comparent les deux thèmes**. Ce sont les
/// seuls contrôles du dépôt qui puissent attraper une divergence clair/sombre,
/// et ils l'attrapent avant l'écran plutôt qu'après.
///
/// ⚠️ Ils ne disent **rien de l'apparence**. Qu'un rayon vaille 24 ne dit pas
/// qu'il est joli ; qu'un contraste vaille 7,9 ne dit pas que l'écran est
/// lisible au soleil. Ce fichier vérifie des invariants, pas un rendu — et le
/// dire évite de le prendre pour une validation de design.
void main() {
  final light = buildAppTheme();
  final dark = buildAppDarkTheme();

  group('identité', () {
    test('la marque est POSÉE, pas dérivée', () {
      // ⚠️ `fromSeed` DÉCALE la graine : sans les rôles redéclarés
      // explicitement, le primaire rendu ne serait pas celui qu'on a choisi, et
      // la couleur du produit serait « à peu près » la bonne. Ce test échoue si
      // quelqu'un retire ces redéclarations en croyant simplifier.
      expect(light.colorScheme.primary, const Color(0xFF4338CA));
      expect(dark.colorScheme.primary, const Color(0xFF5B52E8));
    });

    test('les deux teintes sont le même indigo, pas deux couleurs', () {
      // ⚠️ L'invariant a CHANGÉ le 02/08/2026, et il faut le dire : ce test
      // affirmait « la même teinte sur les deux thèmes », ce que le correctif de
      // contraste a rendu faux. Une valeur unique produisait une AppBar
      // illisible en sombre (voir `app_theme.dart`).
      //
      // Ce qui reste vrai, et qui est la vraie règle, c'est que la marque doit
      // rester **reconnaissable** d'un thème à l'autre : deux valeurs, une seule
      // couleur. Une divergence de teinte serait une seconde marque, et ce test
      // la refuse là où l'égalité stricte refusait la correction elle-même.
      final hl = HSLColor.fromColor(light.colorScheme.primary).hue;
      final hd = HSLColor.fromColor(dark.colorScheme.primary).hue;
      expect((hl - hd).abs(), lessThan(5), reason: 'teintes $hl° et $hd°');
    });

    test('l’accent de famille est partagé par les deux thèmes', () {
      expect(light.colorScheme.secondary, const Color(0xFFF2A93B));
      expect(dark.colorScheme.secondary, const Color(0xFFF2A93B));
    });

    test('les surfaces sont teintées, jamais neutres', () {
      // Le raisonnement du système : c'est le FOND qui porte l'identité, plus
      // encore que l'accent. Un gris neutre y perdrait la famille — et se
      // glisserait sans que personne le remarque, puisqu'un fond ne se regarde
      // pas. Le test vérifie donc qu'aucun des trois canaux n'égale les deux
      // autres, ce qui est la définition d'un gris.
      for (final scheme in [light.colorScheme, dark.colorScheme]) {
        final s = scheme.surface;
        expect(
          (s.r == s.g) && (s.g == s.b),
          isFalse,
          reason: 'surface ${s.toARGB32().toRadixString(16)} est un gris neutre',
        );
      }
    });

    test('l’AppBar porte la marque sur les DEUX thèmes', () {
      // ⚠️ Le sombre posait un gris `#1a1a1a` là où le clair posait la marque :
      // la couleur du produit disparaissait pour qui utilise son téléphone en
      // sombre, c'est-à-dire le soir, c'est-à-dire pendant les livraisons.
      expect(light.appBarTheme.backgroundColor, light.colorScheme.primary);
      expect(dark.appBarTheme.backgroundColor, dark.colorScheme.primary);
    });
  });

  group('typographie', () {
    test('les titres sont en Cairo, le corps en IBM Plex Sans Arabic', () {
      for (final theme in [light, dark]) {
        expect(theme.textTheme.titleLarge?.fontFamily, 'Cairo');
        expect(theme.textTheme.headlineMedium?.fontFamily, 'Cairo');
        expect(theme.textTheme.bodyMedium?.fontFamily, 'IBMPlexSansArabic');
        expect(theme.textTheme.labelLarge?.fontFamily, 'IBMPlexSansArabic');
      }
    });

    test('les interlignes sont posés, jamais laissés au défaut', () {
      // Un `height` nul veut dire « interligne de la police », qui varie d'une
      // famille à l'autre : deux niveaux voisins n'auraient alors pas le même
      // rythme, et la raison serait introuvable.
      for (final style in [
        light.textTheme.headlineMedium,
        light.textTheme.titleLarge,
        light.textTheme.bodyMedium,
        light.textTheme.labelLarge,
      ]) {
        expect(style?.height, isNotNull);
        expect(style!.height, greaterThan(1.0));
      }
    });

    test('l’échelle est celle du système repris', () {
      expect(light.textTheme.headlineMedium?.fontSize, 28); // H1
      expect(light.textTheme.titleLarge?.fontSize, 22); // H2
      expect(light.textTheme.titleMedium?.fontSize, 18); // H3
      expect(light.textTheme.bodyMedium?.fontSize, 15); // corps
      expect(light.textTheme.bodySmall?.fontSize, 12); // caption
      expect(light.textTheme.labelLarge?.fontSize, 14); // bouton
    });
  });

  group('formes', () {
    /// Le rayon d'une forme de composant, quel que soit son emballage.
    double? radiusOf(OutlinedBorder? shape) {
      if (shape is! RoundedRectangleBorder) return null;
      final r = shape.borderRadius;
      return r is BorderRadius ? r.topLeft.x : null;
    }

    test('chaque rayon va au composant auquel il est affecté', () {
      // C'est l'affectation qui fait la silhouette du produit, pas la gamme :
      // une carte au rayon d'un bouton efface la distinction que toute la gamme
      // existe pour faire.
      for (final theme in [light, dark]) {
        expect(radiusOf(theme.cardTheme.shape as OutlinedBorder?), AppRadius.card);
        expect(radiusOf(theme.chipTheme.shape), AppRadius.chip);
      }
    });

    test('les cartes n’ont pas d’ombre, mais une bordure', () {
      // Sur les écrans bon marché de nos transporteurs, une ombre portée bave ;
      // une bordure d'un pixel reste nette. Si l'élévation revient, la bordure
      // devient redondante et le rendu se salit — les deux vont ensemble.
      for (final theme in [light, dark]) {
        expect(theme.cardTheme.elevation, 0);
        final shape = theme.cardTheme.shape as RoundedRectangleBorder;
        expect(shape.side.style, BorderStyle.solid);
        expect(shape.side.color, theme.colorScheme.outlineVariant);
      }
    });
  });

  group('les deux thèmes ne divergent pas', () {
    // ⚠️ Le cœur de ce fichier. Chacun de ces contrôles correspond à une
    // divergence RÉELLE trouvée à l'écran, jamais à une hypothèse.

    test('les boutons ont la même forme en clair et en sombre', () {
      // Défaut constaté : le sombre n'avait aucun style, donc le même écran
      // affichait des coins arrondis en clair et des pilules Material 3 en
      // sombre.
      for (final pair in [
        (light.filledButtonTheme.style, dark.filledButtonTheme.style),
        (light.outlinedButtonTheme.style, dark.outlinedButtonTheme.style),
      ]) {
        expect(pair.$1, isNotNull);
        expect(pair.$2, isNotNull);
        expect(pair.$1!.shape, pair.$2!.shape);
        expect(pair.$1!.padding, pair.$2!.padding);
      }
    });

    test('le bouton bordé compense son contour, dans les deux thèmes', () {
      // Le rembourrage bordé est `plein − 2`, écrit comme une soustraction pour
      // que changer l'un fasse suivre l'autre. Si quelqu'un le repose en
      // littéral, les deux cessent d'être liés — et ce test le dit.
      const states = <WidgetState>{};
      final filled = light.filledButtonTheme.style!.padding!.resolve(states)!;
      final outlined = light.outlinedButtonTheme.style!.padding!.resolve(states)!;
      expect(outlined.vertical, filled.vertical - 4); // 2 px de chaque côté
      expect(outlined.horizontal, filled.horizontal);
    });

    test('les onglets suivent la marque de LEUR thème', () {
      // Défaut constaté : le sombre n'avait aucun thème d'onglets et retombait
      // sur les défauts Material 3 — donc deux apparences pour un même écran.
      //
      // ⚠️ L'égalité entre les deux thèmes n'est PAS l'invariant, et l'écrire
      // ainsi aurait figé le défaut suivant : le thème d'onglets lisait la
      // couleur en dur, donc depuis que le sombre a sa propre teinte il aurait
      // souligné l'onglet actif dans la couleur de l'AUTRE thème. Ce qui doit
      // être vrai des deux côtés, c'est que chacun suit SON primaire.
      for (final theme in [light, dark]) {
        expect(theme.tabBarTheme.labelColor, theme.colorScheme.primary);
        expect(theme.tabBarTheme.indicator, isNotNull);
        expect(theme.tabBarTheme.unselectedLabelColor,
            theme.colorScheme.onSurfaceVariant);
      }
    });

    test('les champs de saisie ont leurs cinq états dans les deux', () {
      // Défaut constaté : le thème posait `BorderSide.none` et RIEN d'autre —
      // pas de `focusedBorder`. Un champ n'avait donc aucun contour au repos ni
      // au focus, et 21 écrans compensaient sans le savoir en repassant leur
      // propre `border`.
      for (final theme in [light, dark]) {
        final input = theme.inputDecorationTheme;
        expect(input.filled, isTrue);
        expect(input.border, isNotNull);
        expect(input.enabledBorder, isNotNull);
        expect(input.focusedBorder, isNotNull);
        expect(input.errorBorder, isNotNull);
        expect(input.focusedErrorBorder, isNotNull);
      }
    });

    test('les couleurs sémantiques existent des deux côtés', () {
      // `ColorScheme` n'a que `error` : sans cette extension, la règle 6 n'a
      // aucun endroit où envoyer un `Colors.green`.
      for (final theme in [light, dark]) {
        expect(theme.extension<AppSemanticColors>(), isNotNull);
      }
      // Et elles ne sont PAS les mêmes : un vert lisible sur fond clair ne l'est
      // pas sur fond sombre — c'est la raison d'être de l'extension plutôt que
      // de deux constantes.
      expect(
        light.extension<AppSemanticColors>()!.success,
        isNot(dark.extension<AppSemanticColors>()!.success),
      );
    });
  });

  group('lisibilité', () {
    /// Luminance relative WCAG.
    double luminance(Color c) {
      double lin(double v) =>
          v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4).toDouble();
      return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
    }

    double contrast(Color a, Color b) {
      final la = luminance(a), lb = luminance(b);
      final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
      return (hi + 0.05) / (lo + 0.05);
    }

    test('le texte de l’AppBar reste lisible sur la marque', () {
      // ⚠️ **Ce test a trouvé un défaut réel à son premier lancement**, et c'est
      // pour ça qu'il vaut plus que les autres : avec une teinte unique posée
      // sur les deux thèmes, Material calculait `onPrimary = #2C2960` en sombre,
      // donc du texte sombre sur une AppBar sombre — 1,67 : 1. Rien ne compilait
      // différemment, rien n'était `null` : la couleur était simplement fausse.
      //
      // C'est le seul endroit où la marque porte du texte, donc le seul où
      // changer la teinte peut rendre l'application illisible en silence.
      for (final theme in [light, dark]) {
        final ratio = contrast(
          theme.colorScheme.primary,
          theme.appBarTheme.foregroundColor!,
        );
        expect(ratio, greaterThan(4.5), reason: 'contraste AppBar $ratio');
      }
    });

    test('la marque se détache du fond de page', () {
      // La contrainte JUMELLE de la précédente, et elle tire dans l'autre sens :
      // éclaircir le primaire pour lisser le texte blanc finirait par le noyer
      // dans le fond en thème clair, et l'assombrir pour qu'il tranche sur un
      // fond clair casse le texte blanc en sombre. Un seul des deux tests
      // laisserait choisir une teinte qui satisfait l'un en ruinant l'autre.
      //
      // 3 : 1 est le seuil WCAG pour un composant d'interface — un `FilledButton`
      // posé sur la page en dépend autant que l'AppBar.
      for (final theme in [light, dark]) {
        final ratio = contrast(
          theme.colorScheme.primary,
          theme.colorScheme.surface,
        );
        expect(ratio, greaterThan(3.0), reason: 'contraste marque/fond $ratio');
      }
    });
  });
}
