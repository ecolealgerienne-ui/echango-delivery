# Audit I18n + centralisation des erreurs (29/07/2026)

Ce document répond à la demande : « vérification complète de toute l'app, respect de l'I18n, pas de code en dur, messages d'erreur avec code + traduction, sélecteur de langue ». Périmètre tranché en amont (voir CLAUDE.md) : **français + arabe (RTL)**, et **la fondation + les messages d'erreur du BFF + le sélecteur** — pas la traduction des ~800 chaînes d'interface (labels, boutons, textes d'aide), documentées ici comme dette plutôt que traitées.

## Ce qui a été vérifié, et ce qui a été trouvé

**Gestion d'erreur non centralisée.** CLAUDE.md ne mentionne ces exigences nulle part avant ce jour — vérifié par recherche dans le fichier (zéro occurrence de « centralis », « code erreur », « i18n » avant cette session). Le BFF comptait **122 sites** répartis sur 10 fichiers qui levaient des exceptions Nest avec un message français en dur et **sans `code`** — `HttpExceptionFilter` ne relayait d'ailleurs pas ce champ avant un correctif de cette même session (§ ci-dessous). Côté client, `AppError` (`lib/errors/app_error.dart`) était un vestige du scaffolding initial : la moitié de ses constantes ne correspondait à aucune route réelle (`authInvalidOtp`, `locationUnavailable`...), et `_parseResponse` écrasait le `code` réel sur les réponses 401/404 avant même de le lire.

## Côté BFF — un registre, pas des chaînes

**`backend/bff/src/common/errors/error-codes.ts`** : registre unique, `export const ErrorCode = {...} as const` — un objet à ~100 entrées `DOMAINE_MOTIF: 'domaine.motif'`, plus le type dérivé `ErrorCode`. **`http-errors.ts`** expose cinq fonctions (`badRequest`, `unauthorized`, `forbidden`, `notFound`, `conflict`) typées `(code: ErrorCode, message: string): never` — un code qui n'existe pas dans le registre est un refus de compilation, pas un bug découvert en recette. C'est la même discipline que `OrderFilters`/`DriverFilters` dans `fleetbase-api.client.ts` (`docs/architecture_bff_fleetbase.md`).

**Les 122 sites des 10 fichiers sont tous convertis** : `auth.service.ts` (23), `cash.service.ts` (13), `geocoding.service.ts` (1), `jwt-auth.guard.ts` (5), `persona.guard.ts` (1), `fleetbase-id.pipe.ts` (1), `flotte.service.ts` (11), `notifications.service.ts` (1), `transporteur.service.ts` (32), `commercant.service.ts` (27) — chaque throw direct de `BadRequestException('texte')` a été remplacé par l'appel typé correspondant, et les imports de classes d'exception Nest devenues mortes ont été retirés fichier par fichier. `npx tsc --noEmit` et `npm run build` passent au vert sur l'ensemble.

**`ValidationPipe`** (`main.ts`) portait le seul point d'entrée HTTP resté hors du registre : sans `exceptionFactory`, un DTO invalide renvoyait les messages `class-validator` bruts (toujours en anglais, jamais de `code`). `common/errors/validation-exception-factory.ts` construit désormais un `BadRequestException({code: 'validation.failed', message, fields})` — `fields` porte les noms de champs invalides (non traduits, à l'usage du développeur). `HttpExceptionFilter` relaie `fields` au même titre que `code` (passthrough, pas de logique dupliquée).

## Côté app — la même taxonomie, traduite deux fois

**`lib/errors/app_error.dart`** réécrit pour miroiter exactement le registre serveur (mêmes chaînes `domaine.motif`), plus une poignée de codes **client-only** documentés comme tels : `network.error`/`timeout.error`/`server.error`/`error.unknown` (constats de connexion, jamais un `code` serveur), `location.permission_denied`/`location.foreground_service_denied` (permissions système), `photo.camera_unavailable`/`photo.empty`/`photo.too_large` (capture photo, échoue avant tout aller-retour réseau), `client.fleet_profile_unavailable`/`client.multiple_profiles_match` (décisions prises côté app, avant que le serveur ait eu son mot à dire).

**`lib/errors/error_translator.dart`** : `translateErrorCode(code, locale)` — deux `Map<String, String>` constantes (`_fr`, `_ar`), une entrée par code. Vérifié par script (pas par relecture) que les trois ensembles — constantes `AppError`, clés `_fr`, clés `_ar` — sont **strictement identiques**, à chaque ajout de code au cours de la session :

```
Codes: 100  FR: 100  AR: 100
Missing FR: set()   Missing AR: set()   Extra FR: set()   Extra AR: set()
```

Un code sans traduction retombe sur un message générique **dans la langue courante**, jamais sur un texte français brut affiché à un utilisateur arabophone — c'est la garantie que ce script vérifie à chaque changement.

**`lib/state/locale_state.dart`** : `ChangeNotifier` qui porte la langue active, persistée (`SharedPreferences`), avec repli sur la locale système **une seule fois**, à défaut de choix déjà enregistré — un choix explicite ne doit pas être écrasé par la locale du téléphone au lancement suivant. **`lib/widgets/language_selector.dart`** : bascule directe (pas de menu à un seul autre choix), posée sur les 4 points d'entrée identifiés — `login_screen.dart`, `dashboard_screen.dart` (transporteur), `orders_screen.dart` (commerçant), `flotte_placeholder_screen.dart`. `main.dart` câble `MaterialApp.router.locale`/`supportedLocales`/`localizationsDelegates` (`GlobalMaterialLocalizations` etc., pré-livrés par le SDK — pas de génération ARB, jamais vérifiable dans ce sandbox sans toolchain Flutter).

## Les 5 classes d'état, et le widget de capture photo

**21 sites** convertis dans `order_state.dart` (5), `merchant_order_state.dart` (11), `cash_state.dart` (2), `driver_presence_state.dart` (2), `auth_state.dart` (1, dans le `_run()` partagé) — chaque `on AppException catch (e) { _errorMessage = e.message; }` devient `_errorMessage = translateErrorCode(e.code, _localeState.locale)`. Les catch génériques (exceptions sans code, parsing, etc.) retombent sur un getter `_genericError` commun plutôt que sur des chaînes françaises en dur dupliquées à chaque site — au passage, cinq paramètres `fallbackError`/`fallback` devenus inutiles ont été retirés des signatures (`_mutateOrder`, `_addressWrite`, `_mutate`, `_run`), plutôt que laissés morts.

`lib/widgets/photo_field.dart` est un cas à part : `PhotoCaptureException` (service de capture photo, aucun aller-retour serveur) portait trois messages français en dur, dont un avec une taille de fichier interpolée. Convertie pour porter un `code` + un `params: {'size': ...}` optionnel ; le widget récupère la locale via `context.read<LocaleState>()` (widget, pas `ChangeNotifier` — pas besoin d'injection au constructeur) et substitue `{size}` dans le message traduit.

**Vérifié par grep sur tout `lib/`** : zéro occurrence de `e.message` ou de `_errorMessage = '...'` restante en dehors du traducteur lui-même.

## Ce qui reste — mesuré, pas estimé

Le chiffre « ~1500 chaînes » cité initialement était une estimation. Mesure réelle à la fin de cette session (`grep` des littéraux `'...'`/`"..."` dans `lib/`) :

| Périmètre | Compte brut | Après filtre grossier* |
|---|---|---|
| `lib/` entier | 2218 | — |
| `lib/screens/` + `lib/widgets/` (texte visible) | 832 | 575 |

*Le filtre exclut les motifs évidemment non-linguistiques (chemins de route, noms d'assets, icônes) — reste une **borne haute approximative**, pas un audit ligne à ligne : une bonne part de ces littéraux sont des clés de champ, des formats de date, des identifiants, pas du texte à traduire. Les fichiers les plus denses en texte : `create_order_screen.dart` (161), `order_detail_screen.dart` transporteur (134) et commerçant (103), `cash_screen.dart` (70), `dashboard_screen.dart` (68).

**Non traduit, délibérément** (décision explicite, pas un oubli) : tous les labels, boutons, titres d'écran, textes d'aide et messages de validation locale (« Renseigner l'email et le mot de passe », etc.) de ces fichiers. Les traiter demanderait soit une extension du traducteur à clé par clé (même mécanique que les erreurs, ~500-800 entrées), soit un passage à `flutter gen-l10n`/ARB — décision reportée, et qui gagnerait à être prise avec un accès à un toolchain Flutter réel pour vérifier la génération (absent de ce sandbox, comme documenté pour le reste du projet Delivery).

## Non vérifié dans ce sandbox

- **`flutter analyze`** : pas de toolchain Flutter ici (limite documentée depuis le début du projet). Tous les fichiers Dart modifiés ont été relus intégralement à la main, avec une vérification automatisée (script Python) de la cohérence stricte entre `AppError`, la table `_fr` et la table `_ar` — mais pas de compilation réelle.
- **Rendu RTL de l'arabe à l'écran** : les délégués `flutter_localizations` sont câblés et `Locale('ar')` est dans `supportedLocales`, ce qui déclenche la `Directionality.rtl` automatique de `MaterialApp` — jamais vu tourner sur un appareil ou un émulateur.
- **Sélecteur de langue à l'usage** : jamais cliqué en pratique, seulement relu.

À rejouer côté utilisateur avant de considérer la fondation i18n close.
