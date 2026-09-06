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

  /// Longueur maximale de la chaîne base64 d'une photo, ~5 Mo d'image.
  ///
  /// Source : `backend/bff/src/transporteur/dto/transporteur.dto.ts`,
  /// `export const MAX_PHOTO_BASE64_LENGTH = 7_000_000`, appliqué par deux
  /// `@MaxLength` (preuve de livraison, signalement d'échec).
  ///
  /// ⚠️ **Le miroir dont la divergence coûte le plus cher du dépôt.** Les autres
  /// font perdre un aller-retour ; celui-ci laisse partir jusqu'à cinq mégaoctets
  /// sur la connexion mobile d'un transporteur avant de revenir en 400. Il vivait
  /// dans `services/photo_service.dart` sous un commentaire disant « doit rester
  /// alignée sur… » — la formule exacte que la règle 5 désigne comme signal
  /// d'extraction, et personne ne l'avait extraite.
  ///
  /// ⚠️ Le serveur l'écrit `7_000_000` : le vérificateur retire les séparateurs
  /// avant de comparer, sans quoi il aurait échoué sur une égalité vraie.
  static const int maxPhotoBase64Length = 7000000;

  /// Prix maximal d'une course, en unité de la devise (DZD).
  ///
  /// Source : `backend/bff/src/commercant/dto/create-order.dto.ts`,
  /// `@Max(500000)` sur `CreateOrderDto.price`.
  ///
  /// ⚠️ Sans garde côté formulaire, une saisie hors borne partait et revenait en
  /// 400 générique ne nommant aucun champ — trouvé par l'audit des écrans du
  /// 04/08/2026.
  static const int orderPriceMax = 500000;

  /// Montant minimal à encaisser à la porte (0 = pas d'encaissement).
  ///
  /// Source : `backend/bff/src/commercant/dto/create-order.dto.ts`,
  /// `@Min(1)` sur `CreateOrderDto.codAmount` — un encaissement de 0 se saisit en
  /// laissant le champ vide, pas en écrivant 0.
  static const int codAmountMin = 1;

  /// Montant maximal à encaisser à la porte.
  ///
  /// Source : `backend/bff/src/commercant/dto/create-order.dto.ts`,
  /// `@Max(500000)` sur `CreateOrderDto.codAmount`.
  static const int codAmountMax = 500000;
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
  ///
  /// ⚠️ **C'est bien une décision locale malgré cette contrainte d'amont**, et
  /// la nuance décide de son emplacement : il n'existe aucun *original*
  /// numérique à comparer — Nominatim publie une politique d'usage, pas une
  /// valeur que le BFF appliquerait. 600 ms est notre réponse à cette
  /// politique, pas une copie. Le jour où le serveur imposerait un délai
  /// chiffré, la valeur passerait dans `ServerRules` avec son vérificateur.
  static const Duration searchDebounce = Duration(milliseconds: 600);

  /// Combien de temps une fiche de commande déjà lue reste affichable sans
  /// lecture bloquante — au tap, elle s'affiche tout de suite et un
  /// rafraîchissement silencieux suit (`DetailCache`, `OrderState.selectOrder`
  /// et `MerchantOrderState.selectOrder`).
  ///
  /// ⚠️ **Décision locale, sans contrainte serveur** : le BFF ne dit rien d'une
  /// durée de cache. 5 min est notre borne de confiance en pure lecture — au
  /// clic sur une action, le serveur revalide de toute façon la transition, et
  /// `_mutateOrder` / le reconciliateur forcent une lecture fraîche. Le seul
  /// écart toléré sur cette fenêtre est un `cod_amount` corrigé en amont.
  static const Duration orderDetailFreshness = Duration(minutes: 5);

  /// Taille d'une page de liste, pour toutes les listes paginées de l'app.
  ///
  /// ⚠️ **Une décision locale, malgré l'apparence.** Le BFF a bien un défaut de
  /// 25 (`flotte.service.ts`, `commercant.service.ts` : `query.limit || 25`),
  /// mais il ne l'**impose** pas : c'est ce qu'il sert quand l'app ne demande
  /// rien. Ce n'est donc pas une contrainte à reproduire — une divergence ne
  /// ferait pas mentir l'écran, elle changerait le nombre de lignes par
  /// chargement. D'où `AppRules` et non `ServerRules`, et pas de vérificateur.
  ///
  /// Ce qu'elle évite, en revanche, est réel : la valeur vivait dans deux
  /// classes d'état et dans les défauts de trois méthodes du client HTTP. En
  /// changer une seule aurait fait demander des pages de 25 à une liste qui en
  /// compte 50 par page — c'est-à-dire sauter une commande sur deux.
  static const int listPageSize = 25;
}
