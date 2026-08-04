import { Injectable } from '@nestjs/common';

/**
 * Un mutex **en-processus**, par clé de ressource : il sérialise des sections
 * critiques asynchrones qui, sinon, s'entrelacent au premier `await`.
 *
 * ── Pourquoi il existe, et ce qu'il ferme ───────────────────────────────────
 *
 * Plusieurs écritures du BFF sont des **lire-modifier-écrire** sur une même
 * ressource Fleetbase — une liste portée par une commande (`declines`,
 * `delivery_failures`), les favoris d'un `Vendor`, l'affectation d'une course.
 * Sans transaction entre systèmes (règle 2), deux requêtes concurrentes lisent
 * la même base, ajoutent chacune la sienne, et le second `PUT` **écrase** le
 * premier : une écriture perdue, en HTTP 200, sans trace. Constaté par
 * `scripts/test-concurrence-fenetres.sh` (favoris : 2 survivants sur 6) et par
 * `test-concurrence-acceptation.sh` (deux conducteurs félicités pour la même
 * course). Ce verrou sérialise ces sections : une seule s'exécute à la fois
 * pour une clé donnée, la suivante voit l'état que la précédente a écrit.
 *
 * ⚠️ **Le verrou ne suffit pas seul — il faut RELIRE dans la section.** Une
 * lecture faite AVANT d'acquérir le verrou est déjà périmée : la sérialisation
 * n'y changerait rien, le second écrivain repartirait de sa copie obsolète.
 * L'appelant doit donc relire la ressource **à l'intérieur** de `withLock`.
 *
 * ⚠️ **En-processus, comme le throttler.** Il sérialise au sein d'UNE instance
 * Node. Le BFF tourne aujourd'hui en instance unique (le limiteur de débit fait
 * déjà cette hypothèse, `status_v1.md`). À plusieurs instances, il faudra un
 * verrou partagé (Redis `SET NX PX` + jeton de propriété) — même échéance VPS
 * que le throttler. Le dire plutôt que de le laisser croire couvert.
 *
 * ── Mécanique ───────────────────────────────────────────────────────────────
 *
 * On tient, par clé, la **queue** des sections en attente sous la forme d'une
 * promesse « fin de la dernière » (`tail`). Une nouvelle section s'accroche à la
 * fin : elle ne démarre qu'une fois la précédente **réglée** — succès OU échec,
 * pour qu'une section qui lève ne bloque pas la file. La clé est retirée dès que
 * plus personne n'attend derrière, pour que la carte ne grossisse pas sans fin.
 */
@Injectable()
export class ResourceLockService {
  private readonly tails = new Map<string, Promise<unknown>>();

  async withLock<T>(key: string, fn: () => Promise<T>): Promise<T> {
    const prev = this.tails.get(key) ?? Promise.resolve();

    // `fn` démarre quand `prev` est réglée, quelle qu'en soit l'issue : les deux
    // branches appellent `fn` une seule fois. Un échec amont ne doit pas
    // empêcher le suivant de s'exécuter — il doit juste attendre son tour.
    const result = prev.then(
      () => fn(),
      () => fn(),
    );

    // La nouvelle queue : « quand cette section est réglée ». Ne rejette jamais,
    // pour que le maillon suivant s'y accroche sans se propager d'erreur.
    const tail: Promise<void> = result.then(
      (): void => undefined,
      (): void => undefined,
    );
    this.tails.set(key, tail);

    // Ménage : si personne ne s'est accroché derrière nous, la clé est libre.
    // (Si un suivant est arrivé, il a remplacé `tail` par le sien : on n'y touche pas.)
    void tail.then(() => {
      if (this.tails.get(key) === tail) this.tails.delete(key);
    });

    return result;
  }
}
