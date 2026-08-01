import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../errors/app_error.dart';
import '../i18n/common_strings.dart';
import '../errors/error_translator.dart';
import '../services/photo_service.dart';
import '../state/locale_state.dart';
import '../theme/app_spacing.dart';

/// Champ de prise de photo, partagé par la preuve de livraison et le
/// signalement d'échec.
///
/// Les deux écrans ont le même besoin et la même contrainte de taille : un
/// seul composant évite qu'ils divergent, comme l'ont fait les deux scripts de
/// test avant d'être réunis.
class PhotoField extends StatefulWidget {
  /// Remonte la photo encodée, ou `null` quand elle est retirée.
  final ValueChanged<CapturedPhoto?> onChanged;

  /// Titre du bloc. `null` ⇒ « Photo », traduit — un défaut de paramètre doit
  /// être constant, donc il ne peut pas appeler la table ; il est résolu au
  /// `build`, où le contexte existe.
  final String? label;
  final String helperText;

  /// Une preuve de livraison est exigée par le serveur sur certaines étapes
  /// (`require_pod`), un signalement d'échec non.
  final bool required;

  const PhotoField({
    super.key,
    required this.onChanged,
    this.label,
    this.helperText = '',
    this.required = false,
  });

  @override
  State<PhotoField> createState() => _PhotoFieldState();
}

class _PhotoFieldState extends State<PhotoField> {
  /// Libellés d'ossature (« Photographier », « Retirer »…).
  String _c(String key, [Map<String, String>? vars]) =>
      commonLabel(key, context.read<LocaleState>().locale, vars);

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
            Text(widget.label ?? _c('common.photo'),
                style: theme.textTheme.titleMedium),
            if (widget.required)
              Text(' *', style: TextStyle(color: theme.colorScheme.error)),
          ],
        ),
        if (widget.helperText.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            widget.helperText,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        if (_photo != null) _preview(theme) else _picker(theme),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.sm),
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
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Image.memory(
            Uint8List.fromList(photo.bytes),
            height: 200,
            fit: BoxFit.cover,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _c('common.photo.size', {'size': '${photo.approximateSizeKb}'}),
              style: theme.textTheme.bodySmall,
            ),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _busy ? null : () => _pick(fromGallery: false),
                  icon: const Icon(Icons.refresh),
                  label: Text(_c('common.photo.retake')),
                ),
                TextButton.icon(
                  onPressed: _busy ? null : _remove,
                  icon: const Icon(Icons.delete_outline),
                  label: Text(_c('common.photo.remove')),
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
        padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => _pick(fromGallery: false),
            icon: const Icon(Icons.camera_alt_outlined),
            label: Text(_c('common.photo.take')),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        // La galerie sert au rattrapage : une photo prise juste avant, hors de
        // l'app, ou une reprise après une coupure. Sans elle, un incident non
        // photographié dans le bon écran est définitivement perdu.
        OutlinedButton(
          onPressed: () => _pick(fromGallery: true),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg, horizontal: AppSpacing.lg),
          ),
          child: const Icon(Icons.photo_library_outlined),
        ),
      ],
    );
  }
}
