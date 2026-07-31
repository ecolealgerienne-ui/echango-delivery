import 'package:flutter_test/flutter_test.dart';

import 'package:echango_delivery/models/cash.dart';

/// Dans quel sens se lit une dette, pour les trois profils.
///
/// ── Pourquoi un test, sur ce qui ressemble à de l'affichage ───────────────
///
/// Parce que ce n'est pas de l'affichage : c'est **qui doit à qui**, et l'écran
/// de caisse le déduisait d'un booléen `isDriver`. Un booléen ne peut pas
/// distinguer trois positions dans une chaîne — l'entreprise de transport est
/// au milieu, ses conducteurs lui doivent et elle doit aux commerçants — donc
/// elle était rangée du côté du commerçant et **la moitié de ses soldes se
/// lisaient à l'envers** : « Détenue par ce transporteur » là où c'est elle qui
/// détient, et qu'elle doit.
///
/// Le sens vient désormais de la **position** de la contrepartie. Les cas
/// ci-dessous sont la table de vérité complète des six couples réels, et deux
/// d'entre eux fixent ce que l'ancienne version affirmait à l'envers.
void main() {
  CashBalance balance(String type, double debt) =>
      CashBalance(counterpartyId: 'x', counterpartyType: type, debt: debt);

  group('position dans la chaîne', () {
    test('conducteur → entreprise → commerçant', () {
      expect(cashChainRank('driver'), lessThan(cashChainRank('fleet')!));
      expect(cashChainRank('fleet'), lessThan(cashChainRank('merchant')!));
    });

    test('un type inconnu ne se devine pas', () {
      expect(cashChainRank('operator'), isNull);
      expect(cashChainRank(null), isNull);
      // Et l'écran doit alors rester neutre plutôt qu'affirmer un sens.
      expect(cashSide('driver', 'operator'), CashSide.unknown);
      expect(cashSide('driver', null), CashSide.unknown);
    });

    test('deux parties du même type n’ont pas de sens ici', () {
      // Le serveur exclut déjà l'acteur de ses propres contreparties ; si le
      // cas survenait, mieux vaut ne rien affirmer.
      expect(cashSide('fleet', 'fleet'), CashSide.unknown);
    });
  });

  group('le conducteur ne fait face qu’à de l’aval', () {
    test('son facilitateur comme son commerçant sont en aval', () {
      expect(cashSide('driver', 'fleet'), CashSide.downstream);
      expect(cashSide('driver', 'merchant'), CashSide.downstream);
    });

    test('une dette positive veut dire qu’il détient', () {
      expect(balance('merchant', 1300).upstreamHolds, isTrue);
    });
  });

  group('le commerçant ne fait face qu’à de l’amont', () {
    test('conducteur et entreprise sont en amont', () {
      expect(cashSide('merchant', 'driver'), CashSide.upstream);
      expect(cashSide('merchant', 'fleet'), CashSide.upstream);
    });
  });

  group('l’entreprise est au MILIEU — le cas que ce lot corrige', () {
    test('ses conducteurs sont en amont, ses commerçants en aval', () {
      expect(cashSide('fleet', 'driver'), CashSide.upstream);
      expect(cashSide('fleet', 'merchant'), CashSide.downstream);
    });

    test('le même signe veut dire deux choses opposées selon le côté', () {
      // +1300 face à un conducteur : c'est LUI qui détient.
      expect(cashSide('fleet', 'driver'), CashSide.upstream);
      // +1300 face à un commerçant : c'est ELLE qui détient, et elle doit.
      expect(cashSide('fleet', 'merchant'), CashSide.downstream);
      // C'est exactement ce qu'un booléen `isDriver` ne pouvait pas exprimer :
      // il rendait la même phrase pour les deux.
    });
  });

  group('les totaux', () {
    CashLedger ledger(List<CashBalance> b) =>
        CashLedger(balances: b, currency: 'DZD');

    test('un acteur de bout de chaîne n’a qu’un côté', () {
      final l = ledger([balance('merchant', 1300), balance('merchant', 650)]);
      expect(l.totalOn(CashSide.downstream, 'driver'), 1950);
      // `null` et non `0` : rien de ce côté, donc rien à afficher. Un `0`
      // aurait montré « vous devez 0 » à qui ne doit à personne.
      expect(l.totalOn(CashSide.upstream, 'driver'), isNull);
    });

    test('l’entreprise lit sa créance et sa dette SÉPARÉMENT', () {
      final l = ledger([
        balance('driver', 1300), // son conducteur détient : elle est créancière
        balance('merchant', 800), // elle détient : elle est débitrice
      ]);

      expect(l.totalOn(CashSide.upstream, 'fleet'), 1300);
      expect(l.totalOn(CashSide.downstream, 'fleet'), 800);

      // ⚠️ Et voici ce que l'écran affichait avant : la DIFFÉRENCE, sous le
      // libellé « Espèces encaissées pour vous ». Un nombre qui ne désigne
      // personne, et qui aurait valu 0 pour une entreprise parfaitement à
      // l'équilibre entre 50 000 dus et 50 000 détenus.
      expect(l.total, 2100);
      expect(l.total, isNot(1300));
      expect(l.total, isNot(800));
    });

    test('une position nulle des deux côtés reste distincte d’une absence', () {
      final l = ledger([balance('driver', 0)]);
      expect(l.totalOn(CashSide.upstream, 'fleet'), 0);
      expect(l.totalOn(CashSide.downstream, 'fleet'), isNull);
    });
  });

  group('nommer la contrepartie', () {
    test('chaque type a son mot', () {
      expect(cashPartyLabel('driver'), 'ce transporteur');
      expect(cashPartyLabel('fleet'), 'cette entreprise');
      expect(cashPartyLabel('merchant'), 'ce commerçant');
    });

    test('un type inconnu ne prend le nom de personne', () {
      expect(cashPartyLabel('operator'), 'cette contrepartie');
      expect(cashPartyLabel(null), 'cette contrepartie');
    });
  });
}
