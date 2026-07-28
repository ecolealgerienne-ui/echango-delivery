import 'dart:convert';

import 'package:image_picker/image_picker.dart';

import '../utils/logger.dart';

/// Longueur maximale de la chaîne base64 acceptée par le BFF.
///
/// Doit rester alignée sur `MAX_PHOTO_BASE64_LENGTH` de
/// `backend/bff/src/transporteur/dto/transporteur.dto.ts` (7 000 000, soit
/// ~5 Mo d'image). Dépassée, la requête part et revient en 400 après avoir
/// consommé la connexion mobile du transporteur — autant refuser avant.
const maxPhotoBase64Length = 7000000;

/// Résultat d'une capture : l'image encodée, prête pour le BFF.
class CapturedPhoto {
  /// Base64 **sans** préfixe `data:` — c'est ce qu'attend le contrôleur
  /// Fleetbase derrière le BFF.
  final String base64;

  /// Octets de l'image, pour l'aperçu à l'écran sans re-décoder.
  final List<int> bytes;

  const CapturedPhoto({required this.base64, required this.bytes});

  int get approximateSizeKb => (bytes.length / 1024).round();
}

/// Erreur de capture destinée à être affichée telle quelle.
class PhotoCaptureException implements Exception {
  final String message;
  const PhotoCaptureException(this.message);

  @override
  String toString() => message;
}

/// Prise de photo pour la preuve de livraison et le signalement d'échec.
///
/// Les contraintes de taille sont appliquées **avant** l'envoi : une photo de
/// smartphone moderne dépasse largement la limite du serveur une fois encodée
/// en base64 (qui gonfle de ~33 %), et le transporteur est justement celui qui
/// a la connexion la plus incertaine.
class PhotoService {
  static final PhotoService _instance = PhotoService._internal();
  factory PhotoService() => _instance;
  PhotoService._internal();

  final ImagePicker _picker = ImagePicker();

  /// Prend une photo avec l'appareil, ou la choisit dans la galerie.
  ///
  /// Renvoie `null` si l'utilisateur annule — un cas normal, pas une erreur.
  /// Lève [PhotoCaptureException] quand la capture a eu lieu mais que le
  /// résultat est inutilisable.
  Future<CapturedPhoto?> capture({bool fromGallery = false}) async {
    final XFile? file;
    try {
      file = await _picker.pickImage(
        source: fromGallery ? ImageSource.gallery : ImageSource.camera,
        // Redimensionnement et compression faits par le plugin, côté natif :
        // 1600 px de large suffisent largement à documenter une livraison, et
        // évitent d'avoir à embarquer une bibliothèque de traitement d'image.
        maxWidth: 1600,
        imageQuality: 70,
      );
    } catch (e) {
      AppLogger.error('PhotoService', 'Capture impossible', e);
      throw const PhotoCaptureException(
        'Impossible d\'ouvrir l\'appareil photo. Vérifiez l\'autorisation '
        'caméra dans les réglages.',
      );
    }

    if (file == null) return null;

    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      throw const PhotoCaptureException('La photo est vide, réessayez.');
    }

    final encoded = base64Encode(bytes);
    if (encoded.length > maxPhotoBase64Length) {
      // Ne devrait pas arriver avec les bornes ci-dessus, mais un appareil
      // peut ignorer `imageQuality` selon le format source.
      throw PhotoCaptureException(
        'Photo trop volumineuse (${(bytes.length / 1024 / 1024).toStringAsFixed(1)} Mo). '
        'Reprenez-la de plus loin ou avec une résolution plus basse.',
      );
    }

    AppLogger.info('PhotoService', 'Photo capturée (${bytes.length ~/ 1024} ko)');
    return CapturedPhoto(base64: encoded, bytes: bytes);
  }
}
