import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../i18n/order_strings.dart';
import '../state/locale_state.dart';
import '../state/merchant_order_state.dart';
import '../widgets/app_snack_bar.dart';

/// Rouvre le formulaire de création **pré-rempli** depuis une livraison passée.
///
/// ── Pourquoi un helper partagé, et pas deux copies ────────────────────────
///
/// Règle 5 : « Refaire cette livraison » est offert à deux endroits — la fiche
/// d'une commande et, depuis le 10/09/2026, sa carte dans la liste des
/// livraisons terminées. Le geste est le même (« une boulangerie livre le même
/// client chaque semaine ») ; si le chemin change — nouveau champ dans le
/// modèle, autre route — il doit changer aux deux endroits, donc il vit ici.
///
/// ⚠️ **Ouvre le formulaire même quand le modèle n'a pas pu être lu** : vide,
/// avec un mot pour dire pourquoi. Un échec de reprise n'est pas une impasse.
Future<void> reorderOrder(BuildContext context, String orderId) async {
  final router = GoRouter.of(context);
  final orderState = context.read<MerchantOrderState>();
  final locale = context.read<LocaleState>().locale;

  final template = await orderState.loadOrderTemplate(orderId);
  if (!context.mounted) return;

  if (template == null) {
    showAppError(
      context,
      orderState.errorMessage ??
          orderLabel('order.detail.duplicate.failed', locale),
    );
  }

  router.push('/commercant/nouvelle', extra: template);
}
