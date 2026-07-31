import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../errors/app_error.dart';
import '../../errors/error_translator.dart';
import '../../i18n/fleet_strings.dart';
import '../../services/bff_api_client.dart';
import '../../state/locale_state.dart';
import '../../widgets/language_selector.dart';
import '../../theme/app_spacing.dart';

/// Les entreprises pour lesquelles ce conducteur roule, et celles qui le
/// demandent.
///
/// ── Pourquoi ce n'est pas un écran administratif ──────────────────────────
///
/// Un rattachement décide **à qui le conducteur devra les espèces** d'une
/// course : `driverCounterparty()` prend le facilitateur de la commande, donc
/// rouler pour deux entreprises, c'est porter deux dettes distinctes. Un
/// conducteur qui ignore pour qui il roule ne peut pas savoir à qui remettre
/// l'argent — et la remise, elle, doit être confirmée par la bonne partie.
///
/// C'est pour cette raison que l'acceptation existe : sans elle, une entreprise
/// rattacherait quelqu'un et lui ferait porter des espèces sans qu'il ait rien
/// accepté. La phrase d'explication en tête d'écran n'est donc pas de la
/// pédagogie décorative, c'est l'énoncé de ce qu'on engage.
///
/// ── L'entreprise d'origine y figure, et elle est marquée ──────────────────
///
/// Celle qui a fait entrer le conducteur dans le réseau (`Driver.vendor_uuid`)
/// apparaît en tête, sans bouton : elle ne se refuse pas depuis l'application.
/// L'omettre aurait montré une liste d'employeurs où le principal manque —
/// justement celui qu'on ne pense pas à vérifier.
class MyFleetsScreen extends StatefulWidget {
  const MyFleetsScreen({super.key});

  @override
  State<MyFleetsScreen> createState() => _MyFleetsScreenState();
}

class _MyFleetsScreenState extends State<MyFleetsScreen> {
  List<Map<String, dynamic>> _fleets = const [];
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _error = null);

    final locale = context.read<LocaleState>().locale;
    try {
      final fleets = await context.read<BffApiClient>().getMyFleets();
      if (!mounted) return;
      setState(() {
        _fleets = fleets;
        _loading = false;
      });
    } on AppException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = translateErrorCode(e.code, locale);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = translateErrorCode(AppError.unknown, locale);
        _loading = false;
      });
    }
  }

  /// Quitter une entreprise, après confirmation.
  ///
  /// La confirmation dit ce que le geste **ne fait pas** : il coupe les courses
  /// à venir, il n'éteint pas la dette. Sans cette phrase, un conducteur
  /// quitterait une entreprise en croyant solder ce qu'il lui doit.
  Future<void> _leave(String membershipId) async {
    final locale = context.read<LocaleState>().locale;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(fleetLabel('driver.fleets.leave.confirm', locale)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(fleetLabel('fleet.cancel', locale)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(fleetLabel('driver.fleets.leave', locale)),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await context.read<BffApiClient>().leaveFleet(membershipId);
    } on AppException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(translateErrorCode(e.code, locale))),
      );
      return;
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(translateErrorCode(AppError.unknown, locale))),
      );
      return;
    }

    if (mounted) await _load();
  }

  Future<void> _respond(String membershipId, bool accept) async {
    final locale = context.read<LocaleState>().locale;
    try {
      await context.read<BffApiClient>().respondToMembership(membershipId, accept: accept);
    } on AppException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(translateErrorCode(e.code, locale))),
      );
      return;
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(translateErrorCode(AppError.unknown, locale))),
      );
      return;
    }

    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LocaleState>().locale;
    String t(String key) => fleetLabel(key, locale);

    return Scaffold(
      appBar: AppBar(
        title: Text(t('driver.fleets.title')),
        actions: const [LanguageSelector()],
      ),
      body: _loading
          ? Center(child: Text(t('fleet.loading')))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(AppSpacing.lg),
                children: [
                  // ⚠️ L'erreur est un bandeau **au-dessus** de la liste et ne la
                  // remplace pas : un rechargement raté ne doit pas effacer des
                  // entreprises parfaitement lisibles.
                  if (_error != null)
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: ListTile(
                        leading: const Icon(Icons.error_outline),
                        title: Text(_error!),
                        trailing: TextButton(
                          onPressed: _load,
                          child: Text(t('fleet.retry')),
                        ),
                      ),
                    ),

                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.info_outline),
                      title: Text(t('driver.fleets.explain')),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),

                  if (_fleets.isEmpty && _error == null)
                    ListTile(
                      title: Text(t('driver.fleets.empty')),
                      subtitle: Text(t('driver.fleets.empty.hint')),
                    ),

                  for (final fleet in _fleets)
                    _FleetRow(fleet: fleet, t: t, onRespond: _respond, onLeave: _leave),
                ],
              ),
            ),
    );
  }
}

class _FleetRow extends StatelessWidget {
  const _FleetRow({
    required this.fleet,
    required this.t,
    required this.onRespond,
    required this.onLeave,
  });

  final Map<String, dynamic> fleet;
  final String Function(String key) t;
  final Future<void> Function(String membershipId, bool accept) onRespond;
  final Future<void> Function(String membershipId) onLeave;

  @override
  Widget build(BuildContext context) {
    final id = fleet['id'] as String?;
    final origin = fleet['origin'] == true;
    final status = fleet['status'] as String? ?? 'pending';
    final pending = !origin && status == 'pending' && id != null;

    return Card(
      child: ListTile(
        leading: Icon(
          status == 'active' ? Icons.business : Icons.pending_outlined,
          color: status == 'active' ? Colors.green : Theme.of(context).colorScheme.outline,
        ),
        title: Text(fleet['name'] as String? ?? '—'),
        subtitle: Text(
          origin ? t('fleet.members.origin') : t('fleet.members.status.$status'),
        ),
        // Trois cas, trois actions différentes — et « Quitter » n'existait pas.
        //
        // Le consentement était à sens unique : un conducteur ayant accepté une
        // fois restait rattaché indéfiniment, seule l'entreprise pouvant
        // suspendre. Un engagement qu'on ne peut pas défaire n'est pas un
        // consentement.
        //
        // L'entreprise d'origine (`origin`) n'a aucun bouton : elle ne se quitte
        // pas depuis l'application.
        trailing: pending
            ? Wrap(
                spacing: 4,
                children: [
                  TextButton(
                    onPressed: () => onRespond(id, false),
                    child: Text(t('driver.fleets.decline')),
                  ),
                  FilledButton(
                    onPressed: () => onRespond(id, true),
                    child: Text(t('driver.fleets.accept')),
                  ),
                ],
              )
            : (!origin && status == 'active' && id != null)
                ? TextButton(
                    onPressed: () => onLeave(id),
                    child: Text(t('driver.fleets.leave')),
                  )
                : null,
      ),
    );
  }
}
