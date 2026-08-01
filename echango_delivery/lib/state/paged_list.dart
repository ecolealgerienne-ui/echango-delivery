import '../config/app_rules.dart';

/// Une liste servie par pages, dont le serveur donne le **total**.
///
/// ── Pourquoi un objet, et pas quatre champs dans chaque classe d'état ─────
///
/// Règle 5, et pas au titre de la ressemblance : si la règle de pagination
/// change — la taille d'une page, la façon de savoir qu'on est au bout, ce
/// qu'on fait d'une page vide — elle doit changer pour **toutes** les listes.
/// Elle était déjà écrite deux fois (`MerchantOrderState`), sur le point de
/// l'être deux fois de plus (courses et opportunités de l'entreprise), et le
/// jour où la quatrième copie aurait divergé, la liste concernée aurait
/// simplement cessé de se compléter — sans erreur, sans message.
///
/// ── Ce que le total apporte, et qu'une page pleine ne dit pas ─────────────
///
/// Sans lui, on ne peut que supposer : « la page est pleine, donc il reste
/// peut-être quelque chose ». Sur un total qui tombe juste, l'app propose un
/// bouton qui ne rapporte rien ; sur un serveur qui rend moins que demandé,
/// elle s'arrête trop tôt. Le total tranche les deux cas.
class PagedList<T> {
  PagedList({this.pageSize = AppRules.listPageSize});

  final int pageSize;

  // ⚠️ **Toujours non modifiable, y compris avant le premier chargement.**
  //
  // Sinon la liste rendue par `items` serait modifiable dans un état et pas
  // dans l'autre : un écran qui trierait « sur place » marcherait tant que la
  // liste est vide, et lèverait à la première page reçue. Une garde qui ne
  // s'applique qu'à partir d'un certain moment n'est pas une garde.
  //
  // `<T>[]` et non `const []` : une liste constante dont le paramètre de type
  // est une variable de type n'est pas une constante — le compilateur la
  // refuse.
  List<T> _items = List<T>.unmodifiable(<T>[]);
  int _total = 0;
  int _loadedPages = 0;
  bool _loadingMore = false;

  List<T> get items => _items;

  /// Ce que le serveur annonce, tous chargements confondus.
  int get total => _total;

  bool get isLoadingMore => _loadingMore;

  /// Reste-t-il quelque chose à charger ?
  bool get hasMore => _items.length < _total;

  /// La page à demander ensuite. Vaut 1 tant que rien n'a été chargé.
  int get nextPage => _loadedPages + 1;

  /// Première page : remplace tout.
  void reset(List<T> items, int total) {
    _items = List.unmodifiable(items);
    _total = total;
    _loadedPages = 1;
  }

  /// Page suivante : ajoute à ce qui est déjà là.
  ///
  /// ⚠️ **Une page vide ferme la liste**, quoi qu'annonce le total. Sans cette
  /// ligne, un total supérieur à ce que le serveur sait rendre — une course
  /// supprimée entre deux lectures, un filtre appliqué après le comptage —
  /// laisse `hasMore` vrai pour toujours : le bouton « charger plus » reste
  /// affiché, ne rapporte rien, et se propose indéfiniment. On préfère
  /// s'arrêter sur ce que le serveur a effectivement servi.
  void append(List<T> items, int total) {
    if (items.isEmpty) {
      _total = _items.length;
      return;
    }
    _items = List.unmodifiable([..._items, ...items]);
    _total = total;
    _loadedPages++;
  }

  /// Reprend le prochain chargement à zéro, sans rien afficher entre-temps.
  ///
  /// Pour les cas où la liste doit être rechargée depuis le début — le contenu
  /// courant reste à l'écran jusqu'à ce que la première page arrive.
  void clear() {
    _items = List<T>.unmodifiable(<T>[]);
    _total = 0;
    _loadedPages = 0;
  }

  /// Ouvre un chargement de page suivante, ou refuse.
  ///
  /// Rend `false` quand il n'y a rien à charger ou qu'un chargement est déjà en
  /// cours — le double appel étant le cas ordinaire d'un bouton pressé deux
  /// fois, ou d'un défilement qui déclenche à chaque image.
  bool beginLoadMore() {
    if (_loadingMore || !hasMore) return false;
    _loadingMore = true;
    return true;
  }

  void endLoadMore() {
    _loadingMore = false;
  }
}
