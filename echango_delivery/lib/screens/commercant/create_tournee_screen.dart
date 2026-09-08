import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/order_strings.dart';
import '../../state/locale_state.dart';
import '../../state/merchant_order_state.dart';
import '../flotte/create_tournee_screen.dart';

/// Composeur de tournée pour le **commerçant** (spec §4, `POST /commercant/tournees`).
///
/// Réutilise `TourneeComposerScreen` (règle 6) — même formulaire que la flotte.
/// Ce qui change : les arrêts peuvent pointer un **dépôt du réseau** (un
/// transporteur favori), et la cible est un **favori** (conducteur ou
/// entreprise) ; aucune cible ⇒ diffusion au pool, que le commerçant suit
/// depuis « Mes commandes » (ligne locale).
class CreateMerchantTourneeScreen extends StatelessWidget {
  const CreateMerchantTourneeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<MerchantOrderState>();
    final locale = context.read<LocaleState>().locale;
    String to(String k) => orderLabel('order.tournee.$k', locale);

    return TourneeComposerScreen(
      config: TourneeComposerConfig(
        depots: [
          for (final d in state.networkDepots) (uuid: d.uuid, name: d.name),
        ],
        targets: [
          (uuid: null, label: to('target.broadcast')),
          for (final f in state.favourites)
            (
              uuid: f.driverUuid,
              label: '${f.name ?? '—'}'
                  '${f.isFleet ? ' · ${to('target.fleet')}' : ''}',
            ),
        ],
        targetLabel: to('target.label'),
        targetHint: to('target.hint'),
        loadDependencies: (ctx) => ctx.read<MerchantOrderState>()
          ..loadFavourites()
          ..loadNetworkDepots(),
        submit: (body) => context.read<MerchantOrderState>().createTournee(body),
      ),
    );
  }
}
