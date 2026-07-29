import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../errors/app_error.dart';
import '../errors/error_translator.dart';
import '../services/photo_service.dart';
import '../state/locale_state.dart';

/// Champ de prise de photo, partagé par la preuve de livraison et le
/// signalement d'échec.
///
/// Les deux écrans ont le même besoin et la même contrainte de taille : un
/// seul composant évite qu'ils divergent, comme l'ont fait les deux scripts de
/// test avant d'être réunis.
class PhotoField extends StatefulWidget {
  /// Remonte la photo encodée, ou `null` quand elle est retirée.
  final ValueChanged<CapturedPhoto?> onChanged;

  final String label;
  final String helperText;

  /// Une preuve de livraison est exigée par le serveur sur certaines étapes
  /// (`require_pod`), un signalement d'échec non.
  final bool required;

  const PhotoField({
    super.key,
    required this.onChanged,
    this.label = 'Photo',
    this.helperText = '',
    this.required = false,
  });

  @override
  State<PhotoField> createState() => _PhotoFieldState();
}

class _PhotoFieldState extends State<PhotoField> {
  CapturedPhoto? _photo;
  String? _error;
  bool _busy = false;

  Future<void> _pick({required bool fromGallery}) async {
    final locale = context.read<LocaleState>().locale;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final photo = await PhotoService().capture(fromGallery: fromGallery);
      // Annulation : on ne touche pas à la photo déjà prise, sans quoi ouvrir
      // l'appareil puis se raviser effacerait une preuve déjà valide.
      if (photo != null) {
        _photo = photo;
        widget.onChanged(photo);
      }
    } on PhotoCaptureException catch (e) {
      var message = translateErrorCode(e.code, locale);
      e.params?.forEach((key, value) {
        message = message.replaceAll('{$key}', value);
      });
      _error = message;
    } catch (e) {
      debugPrint('Capture photo impossible : $e');
      _error = translateErrorCode(AppError.unknown, locale);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _remove() {
    setState(() {
      _photo = null;
      _error = null;
    });
    widget.onChanged(null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(widget.label, style: theme.textTheme.titleMedium),
            if (widget.required)
              Text(' *', style: TextStyle(color: theme.colorScheme.error)),
          ],
        ),
        if (widget.helperText.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            widget.helperText,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 12),
        if (_photo != null) _preview(theme) else _picker(theme),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
      ],
    );
  }

  Widget _preview(ThemeData theme) {
    final photo = _photo!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            Uint8List.fromList(photo.bytes),
            height: 200,
            fit: BoxFit.cover,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${photo.approximateSizeKb} ko',
              style: theme.textTheme.bodySmall,
            ),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _busy ? null : () => _pick(fromGallery: false),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reprendre'),
                ),
                TextButton.icon(
                  onPressed: _busy ? null : _remove,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Retirer'),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _picker(ThemeData theme) {
    if (_busy) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => _pick(fromGallery: false),
            icon: const Icon(Icons.camera_alt_outlined),
            label: const Text('Photographier'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
        ),
        const SizedBox(width: 12),
        // La galerie sert au rattrapage : une photo prise juste avant, hors de
        // l'app, ou une reprise après une coupure. Sans elle, un incident non
        // photographié dans le bon écran est définitivement perdu.
        OutlinedButton(
          onPressed: () => _pick(fromGallery: true),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
          ),
          child: const Icon(Icons.photo_library_outlined),
        ),
      ],
    );
  }
}
