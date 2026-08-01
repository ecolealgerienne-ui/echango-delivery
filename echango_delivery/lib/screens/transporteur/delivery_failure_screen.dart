import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../i18n/order_strings.dart';
import '../../models/order.dart'
    show deliveryFailureLabel, deliveryFailureReasons;
import '../../services/photo_service.dart';
import '../../state/locale_state.dart';
import '../../state/order_state.dart';
import '../../widgets/photo_field.dart';
import '../../theme/app_buttons.dart';
import '../../theme/app_spacing.dart';
import '../../widgets/error_banner.dart';
import '../../widgets/app_snack_bar.dart';
import '../../widgets/section_card.dart';

class DeliveryFailureScreen extends StatefulWidget {
  final String orderId;

  const DeliveryFailureScreen({super.key, required this.orderId});

  @override
  State<DeliveryFailureScreen> createState() => _DeliveryFailureScreenState();
}

class _DeliveryFailureScreenState extends State<DeliveryFailureScreen> {
  String _t(String key, [Map<String, String>? vars]) =>
      orderLabel(key, context.read<LocaleState>().locale, vars);

  late String _selectedReason;
  late TextEditingController _notesController;
  CapturedPhoto? _photo;

  // ⚠️ **Les motifs vivaient ici ET dans `order_detail_screen`, et ils avaient
  // divergé** (01/08/2026) : trois libellés sur six ne s'accordaient plus. Le
  // conducteur déclarait « Client a refusé le colis » quand le commerçant
  // lisait « Colis refusé par le client », pour le même code. La liste et ses
  // libellés vivent désormais dans `models/order.dart`
  // (`deliveryFailureReasons` / `deliveryFailureLabel`), avec le motif complet
  // et le rappel que la valeur envoyée est le CODE, jamais le libellé.

  @override
  void initState() {
    super.initState();
    _selectedReason = deliveryFailureReasons.first;
    _notesController = TextEditingController();
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_t('driver.failure.title')),
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppSectionCard(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      // Accolades obligatoires : `'#$widget.orderId'`
                      // interpolait l'objet `widget` puis affichait « .orderId »
                      // en littéral — l'écran montrait le nom de la classe
                      // suivi d'un fragment de code.
                      _t('driver.order.number', {'id': widget.orderId}),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      _t('driver.failure.intro'),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
            ),
            const SizedBox(height: AppSpacing.xl),
            // Reason Selection
            Text(
              _t('driver.failure.reason'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.md),
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                child: DropdownButton<String>(
                  value: _selectedReason,
                  isExpanded: true,
                  underline: const SizedBox.shrink(),
                  items: deliveryFailureReasons.map((code) {
                    return DropdownMenuItem(
                      value: code,
                      child: Text(deliveryFailureLabel(
                          code, context.read<LocaleState>().locale)),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => _selectedReason = value);
                    }
                  },
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            // Notes
            Text(
              _t('driver.failure.notes'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _notesController,
              decoration: InputDecoration(
                hintText: _t('driver.failure.notes.hint'),
              ),
              maxLines: 4,
            ),
            const SizedBox(height: AppSpacing.xl),
            // La preuve photo n'est pas exigée ici — contrairement à la POD,
            // un échec de livraison n'a pas toujours quelque chose à montrer
            // (destinataire absent). L'imposer pousserait à photographier
            // n'importe quoi pour débloquer l'écran.
            PhotoField(
              label: _t('driver.failure.photo'),
              helperText: _t('driver.failure.photo.hint'),
              onChanged: (photo) => setState(() => _photo = photo),
            ),
            const SizedBox(height: AppSpacing.xxl),
            // Submit Button
            Consumer<OrderState>(
              builder: (context, orderState, _) {
                return FilledButton(
                  onPressed: orderState.isLoading ? null : () => _submitFailureReport(context, orderState),
                  style: AppButtonStyles.destructiveFilled(
                    context,
                    padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
                  ),
                  child: orderState.isLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          // La couleur suit le `foregroundColor` du bouton.
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          _t('driver.failure.submit'),
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                );
              },
            ),
            const SizedBox(height: AppSpacing.lg),
            if (context.watch<OrderState>().errorMessage != null)
              AppErrorBanner(
                message: context.watch<OrderState>().errorMessage!,
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _submitFailureReport(
    BuildContext context,
    OrderState orderState,
  ) async {
    final success = await orderState.reportDeliveryFailure(
      orderId: widget.orderId,
      reason: _selectedReason,
      notes: _notesController.text.isNotEmpty ? _notesController.text : null,
      photoBase64: _photo?.base64,
    );

    if (!context.mounted) return;

    if (success) {
      // Le serveur enregistre le signalement même quand la photo n'a pas pu
      // être jointe. Le taire laisserait le transporteur croire qu'il a fourni
      // un justificatif absent du dossier.
      final photoLost = _photo != null && orderState.lastPhotoUploaded == false;
      // Ni un succès muet, ni un échec : le signalement est enregistré, mais
      // il manque son justificatif. C'est le cas pour lequel `SnackTone.warning`
      // existe.
      showAppSnackBar(
        context,
        photoLost
            ? _t('driver.failure.done.no_photo')
            : _t('driver.failure.done'),
        tone: photoLost ? SnackTone.warning : SnackTone.success,
      );
      // Un seul pop : revenir au détail, qui recharge et affiche désormais le
      // signalement. Deux pops renvoyaient à la liste, où rien ne change —
      // le driver ne voyait aucune trace de ce qu'il venait de déclarer.
      context.pop();
    } else {
      // Sans ça, un échec du signalement ne produisait STRICTEMENT rien à
      // l'écran : ni message, ni navigation. Indiscernable d'un bouton mort.
      showAppError(context, orderState.errorMessage ?? _t('driver.failure.failed'));
    }
  }
}
