import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../services/photo_service.dart';
import '../../state/order_state.dart';
import '../../widgets/photo_field.dart';

class DeliveryFailureScreen extends StatefulWidget {
  final String orderId;

  const DeliveryFailureScreen({super.key, required this.orderId});

  @override
  State<DeliveryFailureScreen> createState() => _DeliveryFailureScreenState();
}

class _DeliveryFailureScreenState extends State<DeliveryFailureScreen> {
  late String _selectedReason;
  late TextEditingController _notesController;
  CapturedPhoto? _photo;

  /// Codes attendus par le BFF (DELIVERY_FAILURE_REASONS, liste fermée
  /// validée côté serveur) associés à leur libellé affiché.
  ///
  /// ⚠️ La valeur envoyée doit être le CODE, pas le libellé : l'écran
  /// envoyait auparavant des libellés anglais ('Recipient not available'),
  /// que la validation serveur rejetait systématiquement en 400.
  ///
  /// La liste suit specs_app_transporteur.md §4.3 — délibérément courte et
  /// spécifique à la livraison, et non les 9 catégories génériques de
  /// Navigator. Deux entrées du scaffolding ont disparu ('Traffic/delay',
  /// 'Vehicle issue') : ce sont des retards, pas des échecs de livraison.
  /// Marquée « à valider avec l'équipe métier » dans la spec.
  static const Map<String, String> _failureReasons = {
    'client_absent': 'Client absent',
    'adresse_introuvable': 'Adresse introuvable',
    'colis_refuse': 'Client a refusé le colis',
    'colis_endommage': 'Colis endommagé ou manquant',
    'acces_impossible': 'Accès impossible (site fermé, zone inaccessible)',
    'autre': 'Autre',
  };

  @override
  void initState() {
    super.initState();
    _selectedReason = _failureReasons.keys.first;
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
        title: const Text('Report Delivery Failure'),
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      // Accolades obligatoires : `'#$widget.orderId'`
                      // interpolait l'objet `widget` puis affichait « .orderId »
                      // en littéral — l'écran montrait le nom de la classe
                      // suivi d'un fragment de code.
                      'Commande ${widget.orderId}',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Report the reason for delivery failure',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.grey[600],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            // Reason Selection
            Text(
              'Failure Reason',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: DropdownButton<String>(
                  value: _selectedReason,
                  isExpanded: true,
                  underline: const SizedBox.shrink(),
                  items: _failureReasons.entries.map((entry) {
                    return DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value),
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
            const SizedBox(height: 24),
            // Notes
            Text(
              'Additional Notes (Optional)',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _notesController,
              decoration: InputDecoration(
                hintText: 'Précisions éventuelles…',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              maxLines: 4,
            ),
            const SizedBox(height: 24),
            // La preuve photo n'est pas exigée ici — contrairement à la POD,
            // un échec de livraison n'a pas toujours quelque chose à montrer
            // (destinataire absent). L'imposer pousserait à photographier
            // n'importe quoi pour débloquer l'écran.
            PhotoField(
              label: 'Photo (facultative)',
              helperText: 'Utile quand l\'échec se constate : porte close, '
                  'adresse introuvable, colis refusé.',
              onChanged: (photo) => setState(() => _photo = photo),
            ),
            const SizedBox(height: 32),
            // Submit Button
            Consumer<OrderState>(
              builder: (context, orderState, _) {
                return ElevatedButton(
                  onPressed: orderState.isLoading ? null : () => _submitFailureReport(context, orderState),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: orderState.isLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        )
                      : const Text(
                          'Signaler l\'échec',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                );
              },
            ),
            const SizedBox(height: 16),
            if (context.watch<OrderState>().errorMessage != null)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  border: Border.all(color: Colors.red),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  context.watch<OrderState>().errorMessage!,
                  style: TextStyle(color: Colors.red.shade700),
                ),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(photoLost
              ? 'Signalement enregistré, mais la photo n\'a pas pu être jointe.'
              : 'Échec de livraison signalé'),
          backgroundColor: photoLost ? Colors.orange.shade800 : null,
        ),
      );
      // Un seul pop : revenir au détail, qui recharge et affiche désormais le
      // signalement. Deux pops renvoyaient à la liste, où rien ne change —
      // le driver ne voyait aucune trace de ce qu'il venait de déclarer.
      context.pop();
    } else {
      // Sans ça, un échec du signalement ne produisait STRICTEMENT rien à
      // l'écran : ni message, ni navigation. Indiscernable d'un bouton mort.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(orderState.errorMessage ?? 'Signalement impossible'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}
