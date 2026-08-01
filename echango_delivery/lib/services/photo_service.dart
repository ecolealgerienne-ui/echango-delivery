import 'dart:convert';

import 'package:image_picker/image_picker.dart';

import '../config/app_rules.dart';
import '../errors/app_error.dart';
import '../utils/logger.dart';

/// Longueur maximale de la chaîne base64 acceptée par le BFF.
///
/// La valeur vit dans [ServerRules.maxPhotoBase64Length], où
/// `tool/check_server_rules.dart` la compare au `MAX_PHOTO_BASE64_LENGTH` du
/// DTO. Elle portait ici un commentaire disant « doit rester alignée sur… », ce
/// qui est précisément l'aveu que rien ne la tenait (règle 5).
///
/// L'alias est conservé pour les appelants ; il ne redéclare pas la valeur.
const maxPhotoBase64Length = ServerRules.maxPhotoBase64Length;

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

/// Erreur de capture, portée par un [code] (voir `errors/app_error.dart`) et
/// traduite à l'écran par `error_translator.dart` — jamais par un message
/// français en dur, ici purement client (aucun aller-retour serveur).
///
/// [params] ne sert qu'au seul cas dynamique ([AppError.photoTooLarge]) : la
/// taille du fichier n'est connue qu'ici, la traduction porte un `{size}` que
/// l'appelant remplace.
class PhotoCaptureException implements Exception {
  final String code;
  final Map<String, String>? params;
  const PhotoCaptureException(this.code, {this.params});
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
      throw const PhotoCaptureException(AppError.photoCameraUnavailable);
    }

    if (file == null) return null;

    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      throw const PhotoCaptureException(AppError.photoEmpty);
    }

    final encoded = base64Encode(bytes);
    if (encoded.length > maxPhotoBase64Length) {
      // Ne devrait pas arriver avec les bornes ci-dessus, mais un appareil
      // peut ignorer `imageQuality` selon le format source.
      throw PhotoCaptureException(
        AppError.photoTooLarge,
        params: {'size': (bytes.length / 1024 / 1024).toStringAsFixed(1)},
      );
    }

    AppLogger.info('PhotoService', 'Photo capturée (${bytes.length ~/ 1024} ko)');
    return CapturedPhoto(base64: encoded, bytes: bytes);
  }
}
