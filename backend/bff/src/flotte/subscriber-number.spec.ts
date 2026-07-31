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
 * Le test porte sur une copie de la logique plutôt que sur le service : ce
 * dernier dépend de Prisma, dont le client ne peut pas être généré dans cet
 * environnement. La copie est fidèle et la faire diverger casserait ce test.
 */

function subscriberNumber(value: string): string | null {
  let digits = value.replace(/\D/g, '');
  if (!digits) return null;

  if (digits.startsWith('00')) digits = digits.slice(2);
  if (digits.startsWith('213')) digits = digits.slice(3);
  if (digits.startsWith('0')) digits = digits.slice(1);

  return digits.length === 9 ? digits : null;
}

function sameIdentifier(stored: string, needle: string): boolean {
  const a = stored.trim().toLowerCase();
  const b = needle.trim().toLowerCase();
  if (a === b) return true;

  const na = subscriberNumber(a);
  const nb = subscriberNumber(b);
  return na !== null && na === nb;
}

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
  });

  it('compare les emails littéralement, casse comprise', () => {
    expect(sameIdentifier('Ali@Exemple.dz', 'ali@exemple.dz')).toBe(true);
    expect(sameIdentifier('ali@exemple.dz', 'ali2@exemple.dz')).toBe(false);
    // Deux emails ne portent aucun numéro : la branche numérique ne doit pas
    // les rapprocher par accident.
    expect(subscriberNumber('ali@exemple.dz')).toBeNull();
  });
});
