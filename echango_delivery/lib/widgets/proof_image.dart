import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/bff_api_client.dart';
import '../i18n/common_strings.dart';
import '../state/locale_state.dart';
import '../theme/app_spacing.dart';

/// Image servie par le BFF, chargée avec le jeton de session.
///
/// ── Pourquoi pas `Image.network` ────────────────────────────────────────────
///
/// La route est protégée par le JWT, et le widget ne porte aucun en-tête
/// d'autorisation. Passer par le client garde le jeton enfermé dans la couche
/// réseau, jamais recopié dans un écran.
///
/// Et jamais l'URL Fleetbase : elle désigne un hôte joignable depuis le seul
/// serveur, et elle n'est protégée par rien — la donner à l'application
/// reviendrait à publier les preuves de livraison à qui devine l'adresse.
///
/// Partagé entre les deux profils : le transporteur produit la preuve, le
/// commerçant la consulte. Deux copies auraient divergé, et c'est justement ce
/// widget qui porte le piège du `FutureBuilder` décrit plus bas.
class ProofImage extends StatefulWidget {
  final String url;

  const ProofImage({super.key, required this.url});

  @override
  State<ProofImage> createState() => _ProofImageState();
}

class _ProofImageState extends State<ProofImage> {
  late Future<Uint8List> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(ProofImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _future = _load();
  }

  // Mémorisé dans l'état, jamais construit dans `build` : un FutureBuilder
  // dont le `future` est recréé à chaque reconstruction relance le
  // téléchargement à chaque fois — et l'écran en contient désormais un par
  // tentative de livraison.
  Future<Uint8List> _load() =>
      context.read<BffApiClient>().fetchImage(widget.url);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox(
            height: 180,
            child: Center(child: CircularProgressIndicator()),
          );
        }

        if (snapshot.hasError || snapshot.data == null) {
          // Dire que la preuve existe : sans ce message, un échec de
          // chargement se lit comme une photo perdue alors qu'elle est bien
          // enregistrée côté serveur.
          return Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Row(
              children: [
                const Icon(Icons.image_not_supported_outlined),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    commonLabel('common.photo.load_failed',
                        context.read<LocaleState>().locale),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          );
        }

        return ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.control),
          child: Image.memory(
            snapshot.data!,
            height: 180,
            width: double.infinity,
            fit: BoxFit.cover,
          ),
        );
      },
    );
  }
}
