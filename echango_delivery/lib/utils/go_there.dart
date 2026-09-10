import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../i18n/driver_strings.dart';
import '../models/order.dart';
import '../services/navigation_launcher.dart';
import '../state/locale_state.dart';
import '../widgets/app_snack_bar.dart';

/// « Y aller » — ouvre l'itinéraire vers le bon point de la course, en un geste.
///
/// ── Pourquoi un helper partagé ────────────────────────────────────────────
///
/// Règle 5 : le geste est offert à trois endroits (la carte de course dans la
/// liste, une épingle sur la carte, la fiche) et doit décider du **même** point
/// — l'enlèvement avant le départ, la livraison après. `NavigationLauncher`
/// tranche le point ; ce helper y ajoute le seul mot d'échec (un bouton muet
/// est indiscernable d'une application figée).
Future<void> goThere(BuildContext context, Order order) async {
  final locale = context.read<LocaleState>().locale;
  final place = NavigationLauncher.relevantPlace(order);
  if (place == null) {
    showAppError(context, driverLabel('driver.order.nav.none', locale));
    return;
  }
  final ok = await NavigationLauncher.navigateTo(place);
  if (context.mounted && !ok) {
    showAppError(context, driverLabel('driver.order.nav.none', locale));
  }
}
