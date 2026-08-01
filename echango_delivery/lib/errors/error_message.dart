import 'dart:ui' show Locale;

import 'app_error.dart';
import 'error_translator.dart';

/// Le message à montrer pour une erreur, quelle qu'elle soit.
///
/// ── L'invariant, et pourquoi il ne tenait à rien ─────────────────────────
///
/// Règle 4 du projet : le serveur renvoie un **code**, l'application traduit.
/// Cette décision — *quel code, pour quelle erreur* — était écrite **34 fois**
/// dans `lib/state/` et un écran, sous la forme d'un couple de `catch` :
///
///     } on AppException catch (e) {
///       X = translateErrorCode(e.code, locale);
///     } catch (_) {
///       X = translateErrorCode(AppError.unknown, locale);
///     }
///
/// Mesuré le 31/07/2026 : tous les sites prenaient bien la même décision, mais
/// dans **trois vocabulaires** — `_localeState.locale` ici, `_locale` là, et un
/// repli tantôt nommé `_genericError`, tantôt réécrit en toutes lettres. Rien
/// n'avait encore divergé sur la décision elle-même ; c'est précisément le
/// moment d'extraire, parce que la copie suivante est celle qui se trompe.
///
/// ⚠️ **Trois sites n'avaient PAS de repli du tout** — `addFavourite`,
/// `removeFavourite` et `loadAddresses` n'attrapaient que `AppException`. Or
/// `getMerchantAddresses` et `addFavouriteDriver` appellent le client HTTP sans
/// envelopper leurs erreurs : un `SocketException` traversait donc le bloc sans
/// être attrapé, et l'exception remontait non gérée pendant que l'écran restait
/// muet. Un quatrième posait le message générique pour TOUTE erreur, code
/// métier compris. Ces quatre-là ne se voyaient pas en lisant un site à la
/// fois — seulement en les mettant côte à côte.
///
/// ── Ce que ça ne fait pas ────────────────────────────────────────────────
///
/// La plomberie reste chez l'appelant : `_isLoading`, `notifyListeners()`, la
/// relecture qui suit une écriture. Ce ne sont pas des décisions partagées mais
/// le fonctionnement propre de chaque classe d'état, et les fusionner
/// obligerait à un paramètre par variante — la duplication déguisée en
/// factorisation.
///
/// Le résultat est aussi employé de six façons différentes (affecté à
/// `_errorMessage`, rendu, glissé dans un enregistrement…). C'est pourquoi
/// cette fonction rend une chaîne et n'écrit nulle part.
String messageForError(Object error, Locale locale) => translateErrorCode(
      // ⚠️ Le repli n'est pas cosmétique : sans lui, une exception réseau ou
      // un défaut de désérialisation remonterait à l'écran en anglais, ou en
      // texte technique. `AppError.unknown` a une traduction dans les deux
      // langues, ce que `dart tool/check_error_codes.dart` vérifie.
      error is AppException ? error.code : AppError.unknown,
      locale,
    );
