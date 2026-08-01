# Signalements amont — prêts à publier

Deux défauts trouvés dans des dépendances tierces, rédigés en anglais pour être
collés tels quels. Ils sont ici plutôt que dans un fil de discussion parce
qu'ils portent chacun un correctif ou un diagnostic que nous avons vérifié, et
qu'un signalement qui reste dans une tête ne corrige rien.

**Aucun des deux ne nous bloque** : le premier est contourné (§1 des règles), le
second n'affecte qu'un outil de confort. Ils sont à publier quand quelqu'un aura
un compte GitHub sous la main.

---

## 1. `fleetbase/fleetops` — `assignDriver()` écrase le `meta` d'une commande

**Dépôt** : https://github.com/fleetbase/fleetops
**Gravité** : perte de données silencieuse, sur le chemin le plus courant.

### Titre proposé

> `assignDriver()` saves an index-resource order without reloading it, wiping `meta`

### Corps

```markdown
### What happens

Assigning a driver from the **orders list** (the `…` menu) destroys the order's
`meta`. After the assignment, `meta` contains only `{"_index_resource": true}`.
Everything that was stored there — in our case price, cash-on-delivery amount,
parcel details and address notes — is gone.

Assigning from the **order detail page** does not lose anything.

### Why

`Http/Resources/v1/Index/Order.php` deliberately returns a partial record and
flags it:

```php
'meta' => ['_index_resource' => true],
```

The flag means "this record is partial, reload before using it", and the console
honours it almost everywhere — `place-actions.js`, `driver-actions.js`,
`vehicle-actions.js` and the order detail route all do:

```js
if (x?.meta?._index_resource) await x.reload();
```

`addon/services/order-actions.js` → `assignDriver()` does **not**. It calls
`loadDriver()`, opens the modal, then `await order.save()`. Ember serialises
every attribute including `meta` — so the flag itself — and the `PUT` overwrites
the real `meta`.

### Suggested fix

Three lines, identical to what the same repository already does elsewhere:

```js
if (order?.meta?._index_resource) await order.reload();
```

`unassignDriver()` performs the same `order.save()` and deserves the same check.

### Impact for us

For a courier, an erased `cod_amount` means no amount announced at the door, a
debt ceiling checked against zero, and a delivery closed without the cash being
recorded while he is holding it.

### Notes

We have moved our business data to custom fields (`custom_field_values`), which
`onAfterUpdate()` only synchronises when the request carries them — so an update
that ignores them leaves them intact. That protects us, but the underlying bug
still affects anyone storing anything in `meta`.
```

---

## 2. `Graphify-Labs/graphify` — un import relatif Dart non résolu crée un nœud fantôme

**Dépôt** : https://github.com/Graphify-Labs/graphify
**Gravité** : le graphe rend des chemins **plausibles et faux**, ce qui est pire
qu'une absence de réponse.

### Titre proposé

> Dart: unresolved relative imports create phantom file nodes, producing plausible-but-wrong paths

### Corps

```markdown
### Environment

- graphifyy 0.9.32, Python 3.12, Windows
- Repository: ~226 files, 86 Dart + 73 TypeScript
- Built with `graphify update .` (no LLM)

### What happens

A Dart file imported through a relative path becomes **two nodes**: the real one
and a phantom whose `source_file` is empty.

```
label='order_strings.dart'            source_file='echango_delivery/lib/i18n/order_strings.dart'
label='../../i18n/order_strings.dart' source_file=''
```

2% of the nodes in our graph (64 of 3956) are phantoms of this kind.

### Why it matters more than a missing edge

Shortest-path queries route **through** the phantoms, so the tool answers with a
path that looks like an answer and is not one. Ground truth: `vehicleLabel`
directly calls `orderLabel`.

```
$ graphify path "vehicleLabel" "orderLabel"
Shortest path (6 hops):
  vehicleLabel <--defines-- vehicle_type.dart --imports--> ../../i18n/order_strings.dart
  <--imports-- merchant_order.dart --imports--> dart:ui
  <--imports-- order_strings.dart --defines--> orderLabel
```

The direct call is absent; the detour through `dart:ui` is presented as the
shortest path. A missing edge makes the user look further — a wrong edge makes
them stop.

### Related: call edges are missing for Dart

`formatRelative` has **degree 1** — the only edge is `dates.dart defines
formatRelative`. Its three real callers do not appear.

Density on the same repository:

| language | edges per node |
|---|---|
| TypeScript (tree-sitter) | 3.83 |
| Dart (regex extractor) | 1.61 |

67% of all nodes have degree ≤ 1. TypeScript queries on the same repo are
correct and direct (2 hops, right answer), so this looks specific to the Dart
extractor rather than to the graph builder.

### Suggested direction

Resolve relative Dart imports against the importing file's directory before
creating a node, so `../../i18n/order_strings.dart` maps onto the existing
`lib/i18n/order_strings.dart` node instead of creating a new one. A node with an
empty `source_file` could also be reported rather than silently linked.

### Note

The README lists Dart among "36 tree-sitter grammars", but `tree-sitter-dart` is
not installed and `graphify/extractors/dart.py` says:

```python
"""Dart extractor. Moved verbatim from graphify/extract.py."""
def extract_dart(path: Path) -> dict:
    """Extract classes, mixins, functions, imports, generic calls, and annotations
    from a .dart file using regex."""
```

Worth aligning the documentation either way — the regex extractor produces good
node coverage (20.4 nodes per file, 0.1% unusable labels), it is the edges that
are thin.
```

---

## Ce qu'ils changent pour nous, une fois corrigés

**Fleetops** : le contournement documenté aux règles §1 (« affecter depuis la
fiche, jamais depuis la liste ») pourra être retiré des consignes aux admins.

**Graphify** : le graphe deviendrait exploitable sur `echango_delivery/`, ce
qu'il n'est pas aujourd'hui — voir l'entrée du 01/08/2026 dans `CLAUDE.md`, qui
conclut « utilisable sur `backend/bff/`, à ne pas croire sur `echango_delivery/` ».
