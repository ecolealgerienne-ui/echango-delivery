import 'package:url_launcher/url_launcher.dart';

import '../models/order.dart';
import '../utils/logger.dart';

/// Ouvre une application de navigation vers un lieu de la commande.
///
/// On délègue plutôt que d'embarquer un guidage : refaire un GPS routier
/// correct (recalcul, trafic, voix, cartes hors ligne) n'a aucun rapport avec
/// ce que ce produit apporte, et le transporteur utilise déjà l'application
/// qu'il connaît.
class NavigationLauncher {
  /// Ouvre l'itinéraire vers [place].
  ///
  /// Renvoie `false` si aucune application ne peut le prendre en charge —
  /// l'appelant doit alors le dire, plutôt que de laisser un bouton sans effet.
  static Future<bool> navigateTo(Place place) async {
    // Coordonnées absentes : le commerçant a saisi une adresse sans passer par
    // la carte (le carnet n'exige que nom et téléphone depuis le 30/07). Mieux
    // vaut refuser que construire un `geo:null,null` qui ouvrirait une carte au
    // hasard.
    //
    // ⚠️ Ce n'est plus le cas d'une course non réclamée : depuis le 31/07/2026,
    // seule l'identité du destinataire est masquée, l'adresse et sa position
    // sont servies. Le motif d'origine cité ici était donc devenu faux.
    final lat = place.latitude;
    final lon = place.longitude;
    if (lat == null || lon == null) return false;

    // `geo:` est l'intent Android standard : il laisse le choix de
    // l'application (Maps, Waze, OsmAnd…) au lieu d'imposer la nôtre. Le
    // paramètre `q` avec le libellé donne une épingle nommée plutôt qu'un
    // point nu, ce qui aide à reconnaître l'adresse à l'arrivée.
    // Le nom est **absent** sur une course non réclamée (c'est celui du
    // destinataire). Sans ce repli, l'épingle s'appelait `()` — une parenthèse
    // vide au milieu d'une carte, qui ressemble à un défaut de l'application.
    final label = Uri.encodeComponent(
      place.name.trim().isEmpty ? place.address : place.name,
    );
    final candidates = <Uri>[
      Uri.parse('geo:$lat,$lon?q=$lat,$lon($label)'),
      // Repli universel, y compris iOS et navigateur : fonctionne partout où
      // `geo:` n'est pas reconnu.
      Uri.parse('https://www.google.com/maps/dir/?api=1'
          '&destination=$lat,$lon'),
    ];

    for (final uri in candidates) {
      try {
        if (await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          return true;
        }
      } catch (e) {
        AppLogger.warn('NavigationLauncher', 'Échec sur $uri : $e');
      }
    }

    return false;
  }

  /// Appelle un contact de la commande.
  ///
  /// Absent sur une course non réclamée : le nom et le téléphone du
  /// destinataire sont la seule chose que le serveur retire tant que personne
  /// ne s'est engagé — l'appelant doit donc masquer le bouton, pas l'offrir
  /// pour rien.
  static Future<bool> call(String phone) async {
    final uri = Uri(scheme: 'tel', path: phone);
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      AppLogger.warn('NavigationLauncher', 'Appel impossible : $e');
      return false;
    }
  }
}
