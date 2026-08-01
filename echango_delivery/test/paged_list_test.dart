import 'package:flutter_test/flutter_test.dart';

import 'package:echango_delivery/config/app_rules.dart';
import 'package:echango_delivery/state/paged_list.dart';

/// Le mécanisme de pagination, éprouvé sur ses cas limites.
///
/// ── Pourquoi ce test, sur quatre-vingts lignes de code ────────────────────
///
/// Parce que ce que ces lignes décident n'est pas « combien de lignes s'affichent »
/// mais **si les plus anciennes sont atteignables**. Deux listes de l'application
/// étaient tronquées à leur première page, en silence — l'entreprise de
/// transport ne voyait plus rien passé sa vingt-cinquième course, et rien ne le
/// disait. Une liste tronquée sans mention se lit comme une liste complète.
///
/// Les cas qui comptent sont ceux où l'on se trompe de bord : la dernière page,
/// la page vide, le double appui. Aucun ne se voit à la lecture.
void main() {
  PagedList<String> list() => PagedList<String>();

  group('avant tout chargement', () {
    test('rien à charger de plus, et la page suivante est la première', () {
      final l = list();
      expect(l.items, isEmpty);
      expect(l.hasMore, isFalse);
      expect(l.nextPage, 1);
      // ⚠️ Le bon défaut : sans total connu on n'invente pas de suite. Le
      // défaut inverse afficherait un bouton « charger plus » qui ne rapporte
      // rien, et le rafficherait à chaque appui.
      expect(l.beginLoadMore(), isFalse);
    });

    test('la taille de page vient d’un seul endroit', () {
      expect(list().pageSize, AppRules.listPageSize);
    });
  });

  group('première page', () {
    test('une page pleine sur un total plus grand laisse une suite', () {
      final l = list()..reset(['a', 'b'], 5);
      expect(l.items, ['a', 'b']);
      expect(l.hasMore, isTrue);
      expect(l.nextPage, 2);
    });

    test('un total atteint ferme la liste', () {
      final l = list()..reset(['a', 'b'], 2);
      expect(l.hasMore, isFalse);
      expect(l.beginLoadMore(), isFalse);
    });

    test('recharger remplace, et ne cumule pas', () {
      final l = list()..reset(['a', 'b'], 5);
      l.reset(['c'], 1);
      expect(l.items, ['c']);
      expect(l.nextPage, 2);
      expect(l.hasMore, isFalse);
    });
  });

  group('pages suivantes', () {
    test('la page s’ajoute, et le compteur avance', () {
      final l = list()..reset(['a', 'b'], 4);
      expect(l.beginLoadMore(), isTrue);
      l.append(['c', 'd'], 4);
      l.endLoadMore();

      expect(l.items, ['a', 'b', 'c', 'd']);
      expect(l.hasMore, isFalse);
      expect(l.nextPage, 3);
    });

    test('un total qui grandit entre deux lectures rouvre la suite', () {
      // Une commande créée pendant la consultation : le serveur fait foi.
      final l = list()..reset(['a'], 2);
      l.append(['b'], 3);
      expect(l.hasMore, isTrue);
    });

    test('une page VIDE ferme la liste, quoi qu’annonce le total', () {
      // Le cas qui, sans traitement, boucle indéfiniment : le total promet une
      // suite que le serveur ne sait plus rendre — une course supprimée entre
      // deux lectures suffit. Le bouton resterait affiché et ne rapporterait
      // jamais rien.
      final l = list()..reset(['a'], 10);
      l.append([], 10);

      expect(l.items, ['a']);
      expect(l.hasMore, isFalse);
      expect(l.total, 1);
      // Et le numéro de page N'AVANCE PAS : rien n'a été chargé.
      expect(l.nextPage, 2);
    });
  });

  group('le double appui', () {
    test('un second chargement pendant le premier est refusé', () {
      final l = list()..reset(['a'], 5);
      expect(l.beginLoadMore(), isTrue);
      // Sans ce refus, la même page serait demandée deux fois — et ajoutée
      // deux fois, ce qu'aucune vérification en aval ne rattraperait.
      expect(l.beginLoadMore(), isFalse);
      expect(l.isLoadingMore, isTrue);

      l.endLoadMore();
      expect(l.isLoadingMore, isFalse);
      expect(l.beginLoadMore(), isTrue);
    });
  });

  group('remise à zéro', () {
    test('clear laisse la liste dans son état d’avant le premier chargement', () {
      final l = list()..reset(['a', 'b'], 5);
      l.clear();
      expect(l.items, isEmpty);
      expect(l.total, 0);
      expect(l.nextPage, 1);
      expect(l.hasMore, isFalse);
    });
  });

  group('la liste rendue ne se modifie pas de l’extérieur', () {
    test('un ajout sur la liste lue lève', () {
      final l = list()..reset(['a'], 1);
      // Sans ça, un écran qui trie ou filtre « sur place » modifierait l'état
      // sans que personne n'en soit notifié.
      expect(() => l.items.add('b'), throwsUnsupportedError);
    });
  });
}
