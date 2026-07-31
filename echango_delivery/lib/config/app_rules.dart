/// Les valeurs qui portent une décision, nommées à un seul endroit.
///
/// ── Deux natures, et il ne faut pas les confondre (règle 7) ───────────────
///
/// **`ServerRules`** reproduit des contraintes que le **serveur** applique. Ce
/// ne sont pas nos décisions : ce sont des copies, et une copie qui diverge de
/// son original fait mentir l'écran. Chacune nomme donc explicitement le
/// fichier dont elle est la copie, et `tool/check_server_rules.dart` **vérifie
/// l'accord par lecture des deux fichiers** — parce qu'un commentaire ne peut
/// pas échouer (règle 5).
///
/// **`AppRules`** porte des décisions **locales**, sans équivalent serveur : un
/// délai d'anti-rebond, un horizon de planification, un nombre de lignes
/// d'aperçu. Rien à synchroniser, mais tout à nommer — une valeur recopiée à
/// trois endroits du même écran finit par diverger de l'un d'eux.
///
/// ── Ce qui n'a rien à faire ici ───────────────────────────────────────────
///
/// Ce qui décrit la **nature d'un widget** : `maxLines: 1`, `shrinkWrap: true`.
/// Ce ne sont pas des décisions, personne ne voudra jamais « changer le nombre
/// de lignes du champ Notes » depuis un fichier de configuration.
///
/// Et l'apparence — marges, rayons, tailles — qui relève des jetons de thème,
/// pas d'ici.
library;

/// Contraintes appliquées par le BFF, reproduites côté app pour éviter un
/// aller-retour dont on connaît d'avance le résultat.
///
/// ⚠️ **Reproduire une règle serveur est un compromis, pas un idéal.** On le
/// fait parce qu'envoyer une requête qu'on sait refusée coûte un aller-retour
/// et rend un message d'erreur là où une consigne suffit. Le prix est la
/// divergence possible, et c'est le vérificateur qui le paie.
class ServerRules {
  ServerRules._();

  /// Longueur minimale d'une recherche de transporteur.
  ///
  /// Source : `backend/bff/src/commercant/dto/driver-search.dto.ts`,
  /// `@MinLength(3)` sur `DriverSearchDto.q`.
  ///
  /// ⚠️ **Trois écrans reproduisaient cette règle et l'un d'eux se trompait** :
  /// l'écran de caisse laissait passer deux caractères (`query.length < 2`), que
  /// le serveur refusait ensuite par une erreur de validation. L'utilisateur
  /// voyait un refus incompréhensible sur une saisie que l'application venait
  /// d'accepter. C'est le défaut exact que la règle 7 décrit, et il était déjà
  /// là — trouvé le 31/07/2026 en instruisant le chantier.
  static const int driverSearchMinLength = 3;

  /// Longueur minimale d'une recherche d'adresse (géocodage).
  ///
  /// Source : `backend/bff/src/commercant/dto/geocode.dto.ts`,
  /// `@MinLength(3)` sur `GeocodeQueryDto.q`.
  static const int addressSearchMinLength = 3;

  /// Longueur minimale d'un mot de passe.
  ///
  /// Source : `backend/bff/src/auth/dto/register.dto.ts`, `@MinLength(8)` —
  /// présent sur les trois DTO d'inscription (commerçant, flotte, transporteur).
  ///
  /// ⚠️ Une **troisième** valeur existait dans `lib/validation/validators.dart`
  /// (`length < 6`), fichier mort mais parfaitement utilisable : le prochain qui
  /// aurait cherché un validateur y aurait trouvé une règle plus permissive que
  /// le serveur. Le fichier a été supprimé le 31/07/2026.
  static const int passwordMinLength = 8;
}

/// Décisions locales à l'application : rien à synchroniser, tout à nommer.
class AppRules {
  AppRules._();

  /// Jusqu'à quand un commerçant peut planifier une livraison.
  ///
  /// ⚠️ **Aucune contrainte serveur ne l'accompagne** — `CreateOrderDto.scheduledAt`
  /// n'est qu'un `@IsISO8601()`. C'est donc une limite purement d'interface :
  /// le serveur accepterait une date à deux ans. Le dire ici évite de croire à
  /// une règle métier là où il n'y a qu'un sélecteur de date borné.
  static const Duration schedulingHorizon = Duration(days: 14);

  /// Attente avant de lancer une recherche pendant la frappe.
  ///
  /// Protège aussi le géocodeur : Nominatim plafonne à une requête par seconde
  /// et interdit les usages intensifs (`.env.example`, `NOMINATIM_URL`).
  static const Duration searchDebounce = Duration(milliseconds: 600);

  /// Nombre d'encaissements détaillés sur l'écran de caisse.
  ///
  /// ⚠️ La valeur apparaissait **trois fois dans le même bloc** : `take(20)`,
  /// `length > 20`, et « 20 dernières livraisons » **dans le texte affiché**.
  /// En changer une seule aurait fait mentir l'écran — vingt-cinq lignes sous un
  /// titre en annonçant vingt.
  static const int cashCollectionsPreview = 20;
}
