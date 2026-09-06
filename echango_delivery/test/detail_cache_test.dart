import 'package:flutter_test/flutter_test.dart';

import 'package:echango_delivery/state/detail_cache.dart';

/// Le cache « servir vite, revalider en fond » des fiches de détail.
///
/// ── Ce que ces lignes décident ───────────────────────────────────────────
///
/// Pas « on gagne un aller-retour » mais **combien de temps un écran peut
/// montrer un état périmé sans le revérifier**. Les cas qui comptent sont les
/// bords : l'entrée qui vient d'expirer, l'entrée retirée parce que devenue
/// fausse, la purge qui doit se déclencher pour ne pas garder tout l'historique.
/// Aucun ne se voit à la lecture.
void main() {
  group('fresh', () {
    test('rend la valeur tant qu\'elle est dans la fenêtre', () {
      final cache = DetailCache<int>(const Duration(minutes: 5));
      cache.put('a', 42);
      expect(cache.fresh('a'), 42);
    });

    test('rend null pour une clé jamais vue', () {
      final cache = DetailCache<int>(const Duration(minutes: 5));
      expect(cache.fresh('inconnue'), isNull);
    });

    test('rend null une fois la fenêtre passée', () async {
      final cache = DetailCache<int>(const Duration(milliseconds: 20));
      cache.put('a', 42);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      // ⚠️ Le bon défaut : périmé ⇒ on ne sert plus sans lecture bloquante.
      // L'inverse laisserait une fiche vieille de plusieurs minutes passer
      // pour fraîche.
      expect(cache.fresh('a'), isNull);
    });
  });

  group('evict', () {
    test('retire une entrée devenue fausse', () {
      final cache = DetailCache<int>(const Duration(minutes: 5));
      cache.put('a', 1);
      cache.evict('a');
      expect(cache.fresh('a'), isNull);
    });

    test('sur une clé absente ne lève pas', () {
      final cache = DetailCache<int>(const Duration(minutes: 5));
      expect(() => cache.evict('absente'), returnsNormally);
    });
  });

  group('put', () {
    test('remplace la valeur ET rafraîchit l\'horodatage', () async {
      final cache = DetailCache<int>(const Duration(milliseconds: 40));
      cache.put('a', 1);
      await Future<void>.delayed(const Duration(milliseconds: 25));
      cache.put('a', 2);
      await Future<void>.delayed(const Duration(milliseconds: 25));
      // 50 ms depuis le premier put, 25 depuis le second : encore frais.
      expect(cache.fresh('a'), 2);
    });

    test('purge les entrées périmées au passage', () async {
      final cache = DetailCache<int>(const Duration(milliseconds: 20));
      cache.put('vieille', 1);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      cache.put('neuve', 2);
      // La vieille n'est pas seulement invisible à `fresh` : elle a été
      // retirée de la table pour qu'un conducteur qui ouvre vingt fiches en
      // dix minutes n'en garde pas vingt.
      expect(cache.entryCount, 1);
      expect(cache.fresh('vieille'), isNull);
      expect(cache.fresh('neuve'), 2);
    });
  });
}
