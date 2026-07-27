import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../state/order_state.dart';

class DeliveryFailureScreen extends StatefulWidget {
  final String orderId;

  const DeliveryFailureScreen({super.key, required this.orderId});

  @override
  State<DeliveryFailureScreen> createState() => _DeliveryFailureScreenState();
}

class _DeliveryFailureScreenState extends State<DeliveryFailureScreen> {
  late String _selectedReason;
  late TextEditingController _notesController;

  static const List<String> _failureReasons = [
    'Recipient not available',
    'Address not found',
    'Recipient refused',
    'Item damaged',
    'Traffic/delay',
    'Vehicle issue',
    'Other',
  ];

  @override
  void initState() {
    super.initState();
    _selectedReason = _failureReasons.first;
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
                      'Order #$widget.orderId',
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
                  items: _failureReasons.map((reason) {
                    return DropdownMenuItem(
                      value: reason,
                      child: Text(reason),
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
                hintText: 'Add any additional details...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              maxLines: 4,
            ),
            const SizedBox(height: 24),
            // Photo section (MVP: placeholder)
            Card(
              color: Colors.blue.shade50,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Icon(
                      Icons.camera_alt_outlined,
                      size: 48,
                      color: Colors.blue.shade700,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Photo Evidence (MVP: Optional)',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.blue.shade700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Photo capture will be available in future updates',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey[600],
                      ),
                    ),
                  ],
                ),
              ),
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
                          'Submit Failure Report',
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
    );

    if (success) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Delivery failure reported')),
      );
      context.pop();
      context.pop();
    }
  }
}
