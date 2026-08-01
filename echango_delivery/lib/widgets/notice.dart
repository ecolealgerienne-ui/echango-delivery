import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/common_strings.dart';
import '../state/locale_state.dart';

import '../theme/app_semantic_colors.dart';
import '../theme/app_spacing.dart';

/// Un message encadré, **dans le flux du contenu**.
///
/// ── Ce que c'est, et ce que ce n'est pas ──────────────────────────────────
///
/// ⚠️ **À ne pas confondre avec `AppErrorBanner`.** Celui-ci se pose en tête
/// d'écran, pleine largeur, et signale que le *chargement* a échoué — il ne
/// remplace jamais le contenu, parce qu'un rafraîchissement raté ne doit pas
/// effacer ce qui était lisible. Un `AppNotice`, lui, **fait partie** du
/// contenu : il dit quelque chose sur la chose affichée, à l'endroit où elle
/// est affichée. « Brouillon : personne n'est sollicité », « le nom du
/// destinataire arrive une fois la course prise ».
///
/// Les deux existent donc pour deux raisons, et les fusionner reviendrait à
/// poser un message de contenu là où seul un message de chargement a sa place.
///
/// ── Pourquoi il fallait l'extraire (règle 6) ──────────────────────────────
///
/// Mesuré le 01/08/2026 : **onze sites, deux mises en page**, pour la même
/// intention.
///
///  * `Card(color: …) > ListTile(leading: Icon, title: Text)` — six fois, dans
///    quatre fichiers de trois profils différents ;
///  * un `Container` avec `BoxDecoration` et un rayon — cinq fois, dans le seul
///    écran de détail commerçant, via un helper privé `_banner(color, icon,
///    text)`. La preuve que le motif avait déjà été reconnu, mais nommé à un
///    seul endroit.
///
/// ⚠️ **Cette extraction n'est donc PAS à aspect constant, et c'est délibéré**
/// — c'est la seule du lot dans ce cas. Les six `Card > ListTile` perdent leur
/// élévation et leur marge Material par défaut au profit du bandeau plat que le
/// commerçant employait déjà. On aligne les profils entreprise et transporteur
/// sur le commerçant, ce qui est exactement ce qui a été demandé après avoir
/// constaté que « le thème entre le commerçant et le facilitateur est
/// différent ». Il ne l'était pas : c'est son application qui l'était.
///
/// ── La règle que le composant porte ───────────────────────────────────────
///
/// **Le ton vient de l'intention, pas d'une couleur choisie à l'appel.** Le
/// helper privé prenait une `Color` en premier argument : rien n'empêchait deux
/// écrans de dire la même chose en deux couleurs. Ici, six constructeurs
/// nommés — et l'appelant choisit ce qu'il *veut dire*, pas ce qu'il veut voir.
class AppNotice extends StatelessWidget {
  /// Une information neutre sur ce qui est affiché.
  const AppNotice.info({
    super.key,
    required this.message,
    required this.icon,
    this.title,
  })  : _tone = _Tone.info,
        onRetry = null,
        retryLabel = null;

  /// Une étape franchie, la suite étant encore à venir.
  ///
  /// ⚠️ Distinct de [AppNotice.success], qui est **terminal**. « Transporteur
  /// affecté, la course démarrera à l'enlèvement » n'est pas « livraison
  /// effectuée » : les afficher pareil ferait croire une course finie.
  const AppNotice.progress({
    super.key,
    required this.message,
    required this.icon,
    this.title,
  })  : _tone = _Tone.progress,
        onRetry = null,
        retryLabel = null;

  /// Ce qui appelle l'attention sans être un échec — une attente qui dure, un
  /// écart constaté.
  const AppNotice.warning({
    super.key,
    required this.message,
    required this.icon,
    this.title,
  })  : _tone = _Tone.warning,
        onRetry = null,
        retryLabel = null;

  /// Un état favorable, **constaté et terminal** — livrée, confirmée.
  const AppNotice.success({
    super.key,
    required this.message,
    required this.icon,
    this.title,
  })  : _tone = _Tone.success,
        onRetry = null,
        retryLabel = null;

  /// Un état terminal sans reproche : annulée, expirée.
  const AppNotice.muted({
    super.key,
    required this.message,
    required this.icon,
    this.title,
  })  : _tone = _Tone.muted,
        onRetry = null,
        retryLabel = null;

  /// Quelque chose a échoué **sur ce contenu-ci**.
  ///
  /// L'icône n'est pas un paramètre : un message d'erreur qui ne porterait pas
  /// l'icône d'erreur se lirait comme une information ordinaire.
  ///
  /// [onRetry] absent, aucun bouton n'est affiché — proposer « Réessayer » là
  /// où rien ne se recharge serait une promesse vide, même règle que
  /// `AppErrorBanner`.
  const AppNotice.error({
    super.key,
    required this.message,
    this.title,
    this.onRetry,
    this.retryLabel,
  })  : _tone = _Tone.error,
        icon = Icons.error_outline;

  /// Le message, **déjà traduit**. Le composant n'appelle pas le traducteur :
  /// les écrans n'ont pas tous la même table (`fleet_strings`, `cash_strings`,
  /// ou du français en dur là où la dette i18n n'est pas encore soldée).
  final String message;

  /// Titre facultatif, au-dessus du message. Présent sur les deux sites qui
  /// nomment l'état avant de l'expliquer (« Course non réclamée » puis ce qui
  /// apparaît à l'acceptation).
  final String? title;

  final IconData icon;
  final VoidCallback? onRetry;
  final String? retryLabel;
  final _Tone _tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (Color background, Color foreground) = switch (_tone) {
      _Tone.error => (scheme.errorContainer, scheme.onErrorContainer),
      _Tone.info => (scheme.secondaryContainer, scheme.onSecondaryContainer),
      _Tone.progress => (scheme.primaryContainer, scheme.onPrimaryContainer),
      // ⚠️ `warning` et `success` ne sont **pas** des rôles de `ColorScheme` —
      // ils viennent de l'extension de thème du dépôt, exactement comme aux
      // sites qui employaient déjà `context.semantic.*`. Prendre
      // `tertiaryContainer` à la place aurait changé la couleur d'états que
      // l'application affiche déjà en vert et en orange.
      _Tone.warning =>
        (context.semantic.warningContainer, context.semantic.onWarningContainer),
      _Tone.success =>
        (context.semantic.successContainer, context.semantic.onSuccessContainer),
      // ⚠️ `outlineVariant` et non `surfaceVariant` : ce dernier est **déprécié**
      // et `flutter analyze` le signale. C'est aussi la couleur que l'écran
      // employait déjà pour une course annulée — le ton ne change donc pas.
      _Tone.muted => (scheme.outlineVariant, scheme.onSurfaceVariant),
    };

    final body = title == null
        ? Text(message, style: TextStyle(color: foreground))
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title!,
                style: theme.textTheme.titleSmall?.copyWith(color: foreground),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(message, style: TextStyle(color: foreground)),
            ],
          );

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      // ⚠️ `center` et non `start`, alors qu'un message à deux lignes
      // demanderait plutôt `start` : le bouton « Réessayer » a une hauteur
      // minimale de 36 px, donc en `start` l'icône et le texte se collent en
      // haut d'une rangée dimensionnée par le bouton — un décalage visible sur
      // les deux bandeaux d'erreur qui en portent un. C'est aussi ce que
      // faisaient `_banner` et `AppErrorBanner`.
      child: Row(
        children: [
          Icon(icon, size: 20, color: foreground),
          const SizedBox(width: AppSpacing.md),
          Expanded(child: body),
          if (onRetry != null) ...[
            const SizedBox(width: AppSpacing.sm),
            TextButton(
              onPressed: onRetry,
              child: Text(
                  retryLabel ??
                      commonLabel('common.retry',
                          context.read<LocaleState>().locale),
                  style: TextStyle(color: foreground)),
            ),
          ],
        ],
      ),
    );
  }
}

enum _Tone { info, progress, warning, success, muted, error }
