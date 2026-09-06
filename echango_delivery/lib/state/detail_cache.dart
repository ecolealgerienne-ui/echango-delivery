/// Un cache « servir vite, revalider en fond » pour les fiches de détail.
///
/// ── Pourquoi il existe ───────────────────────────────────────────────────
///
/// Les deux états de commande — `OrderState` (conducteur) et
/// `MerchantOrderState` (commerçant) — relisaient la fiche du serveur à chaque
/// ouverture, spinner bloquant compris, alors que la liste d'où vient le tap
/// est déjà en mémoire. Un aller-retour liste ↔ fiche coûtait `GET
/// .../commandes/:id` **plus** une seconde requête (transitions côté
/// conducteur, suivi côté commerçant).
///
/// ── Le compromis, et pourquoi il tient ───────────────────────────────────
///
/// Servir une fiche de moins de [freshness] sans la revérifier serait risqué
/// si l'écran agissait sur elle à l'aveugle. Ce n'est pas le cas : **toute
/// écriture est validée par le serveur au moment du clic** (le BFF refait la
/// lecture, une transition périmée revient en erreur codée). Le seul écart
/// visible en pure lecture est un `cod_amount` corrigé en amont — fenêtre de
/// [freshness], rare, et sans conséquence tant qu'aucune clôture n'a lieu
/// pendant.
///
/// ── Ce que cette classe NE fait pas ──────────────────────────────────────
///
/// Elle ne sait pas composer une fiche : quelles requêtes la forment, comment
/// reconnaître « la fiche encore ouverte » avant d'appliquer une révalidation,
/// quand forcer une lecture fraîche après une action — tout cela reste à
/// l'appelant, parce que c'est là que conducteur et commerçant diffèrent. Elle
/// tient seulement la table, les horodatages et la règle de péremption — la
/// part qui, recopiée, finirait par diverger (règle 5).
library;

import 'package:flutter/foundation.dart' show visibleForTesting;

class DetailCache<T> {
  DetailCache(this.freshness);

  /// Au-delà de cette ancienneté, une entrée n'est plus servie sans lecture
  /// bloquante. C'est la borne de confiance, pas une durée de vie : une entrée
  /// plus vieille est ignorée, la révalidation de fond la remplace.
  final Duration freshness;

  final Map<String, ({T value, DateTime at})> _entries = {};

  /// La valeur en cache si elle a moins de [freshness], sinon `null`.
  T? fresh(String key) {
    final entry = _entries[key];
    if (entry == null) return null;
    return DateTime.now().difference(entry.at) < freshness ? entry.value : null;
  }

  /// Enregistre une valeur fraîchement lue, et purge au passage les entrées
  /// périmées — un conducteur qui ouvre vingt fiches en dix minutes n'en garde
  /// ainsi qu'une poignée, jamais l'historique complet.
  void put(String key, T value) {
    final cutoff = DateTime.now().subtract(freshness);
    _entries.removeWhere((_, entry) => entry.at.isBefore(cutoff));
    _entries[key] = (value: value, at: DateTime.now());
  }

  /// Retire une entrée devenue fausse — une course refusée, une commande
  /// introuvable.
  void evict(String key) => _entries.remove(key);

  /// Nombre d'entrées retenues, pour vérifier que [put] purge bien.
  @visibleForTesting
  int get entryCount => _entries.length;
}
