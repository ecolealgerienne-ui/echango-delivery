/**
 * La normalisation des numéros qui fonde le refus de doublon.
 *
 * ── Pourquoi ce test existe ────────────────────────────────────────────────
 *
 * La première version comparait les chiffres bruts par `endsWith`, et elle
 * échouait sur **l'exemple donné dans son propre commentaire** : « 0555 12 34
 * 56 » contre « +213555123456 ». Le zéro de tête du format local n'existe pas
 * dans le format international, donc aucun des deux ne se termine par l'autre.
 * C'est précisément le couple le plus fréquent en Algérie — enregistré en
 * `+213…`, ressaisi en `0…` — donc le doublon que toute la fonctionnalité
 * existe pour empêcher passait, sur le cas le plus courant.
 *
 * Trouvé par un agent de vérification qui a **exécuté** la fonction, pas par
 * relecture. La leçon tient en une ligne : une règle de comparaison ne se relit
 * pas, elle se joue sur ses cas.
 *
 * ⚠️ **Ce test portait une COPIE de la logique**, et l'invoquait ainsi : le
 * service dépend de Prisma, dont le client ne peut pas être généré ici. La
 * justification tenait, la conclusion non — il suffisait d'extraire les deux
 * fonctions dans un module qui n'importe rien.
 *
 * Et la copie **avait déjà divergé** au moment où on l'a relue : le service
 * commençait par `if (typeof stored !== 'string' || !stored.trim()) return
 * false;`, la copie non. Un `null` en base — cas courant, `email` et `phone`
 * étant tous deux facultatifs — passait donc par un chemin que ce test ne
 * parcourait pas. Un test qui recopie ce qu'il vérifie ne vérifie que
 * lui-même : il serait resté vert pendant que les deux versions s'éloignaient.
 *
 * Il importe désormais ce que le service exécute (règle 5).
 */

import { sameIdentifier, subscriberNumber } from '../common/identity/subscriber-number';

describe('reconnaître deux fois la même personne', () => {
  it('reconnaît le format local et le format international', () => {
    // Le cas exact qui échouait, et la raison d'être de la fonction.
    expect(sameIdentifier('0555 12 34 56', '+213555123456')).toBe(true);
    expect(sameIdentifier('0555123456', '+213555123456')).toBe(true);
    expect(sameIdentifier('+213555123456', '0555123456')).toBe(true);
    expect(sameIdentifier('00213555123456', '0555123456')).toBe(true);
  });

  it('tolère les espaces, points et tirets de saisie', () => {
    expect(sameIdentifier('0555-12-34-56', '0555 12 34 56')).toBe(true);
    expect(sameIdentifier('0555.12.34.56', '+213 555 12 34 56')).toBe(true);
  });

  it('ne confond pas deux numéros qui partagent leur fin', () => {
    // L'ancienne version, sur six chiffres et `endsWith`, les déclarait
    // identiques — et refusait donc une création parfaitement légitime.
    expect(sameIdentifier('0555123456', '123456')).toBe(false);
    expect(sameIdentifier('0555123456', '0666123456')).toBe(false);
  });

  it('ne fonde aucun refus sur un numéro incomplet', () => {
    // Trop court pour être un numéro : on préfère laisser créer un doublon
    // réparable plutôt que refuser une embauche sur une chaîne ambiguë.
    expect(subscriberNumber('0555')).toBeNull();
    expect(subscriberNumber('12')).toBeNull();
    expect(sameIdentifier('0555', '0555')).toBe(true); // égalité littérale, elle

    // ⚠️ Cas ajouté après avoir MUTÉ la fonction : assouplir la longueur
    // exigée (`=== 9` en `>= 6`) laissait les cinq autres cas au vert. Deux
    // fragments trop courts mais dont les chiffres coïncident après
    // normalisation — ici `00123456` et `123456` — se seraient déclarés la
    // même personne, et une embauche légitime aurait été refusée.
    expect(sameIdentifier('00123456', '123456')).toBe(false);
    expect(sameIdentifier('0213456789', '213456789')).toBe(false);
  });

  it('ne rapproche rien d’une valeur absente', () => {
    // ⚠️ **Le cas que la copie masquait.** `email` et `phone` sont tous deux
    // facultatifs sur un conducteur Fleetbase : `stored` vaut donc souvent
    // `null`, parfois une chaîne vide, et rien n'interdit un nombre. Sans ce
    // contrôle, `null.trim()` lèverait au milieu d'un contrôle de doublon —
    // c'est-à-dire qu'une création légitime échouerait par une erreur 500.
    //
    // Le service le testait, la copie du test non. C'est exactement le trou
    // qu'un test auto-recopié laisse ouvert.
    expect(sameIdentifier(null, '0555123456')).toBe(false);
    expect(sameIdentifier(undefined, '0555123456')).toBe(false);
    expect(sameIdentifier('', '0555123456')).toBe(false);
    expect(sameIdentifier('   ', '0555123456')).toBe(false);
    expect(sameIdentifier(213555123456, '0555123456')).toBe(false);
  });

  it('compare les emails littéralement, casse comprise', () => {
    expect(sameIdentifier('Ali@Exemple.dz', 'ali@exemple.dz')).toBe(true);
    expect(sameIdentifier('ali@exemple.dz', 'ali2@exemple.dz')).toBe(false);
    // Deux emails ne portent aucun numéro : la branche numérique ne doit pas
    // les rapprocher par accident.
    expect(subscriberNumber('ali@exemple.dz')).toBeNull();
  });
});
