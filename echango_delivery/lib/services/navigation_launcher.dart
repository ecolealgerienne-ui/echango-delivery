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
    // Coordonnées absentes : course non réclamée, le BFF les a retirées avec
    // l'adresse. Mieux vaut refuser que construire un `geo:null,null` qui
    // ouvrirait une carte au hasard.
    final lat = place.latitude;
    final lon = place.longitude;
    if (lat == null || lon == null) return false;

    // `geo:` est l'intent Android standard : il laisse le choix de
    // l'application (Maps, Waze, OsmAnd…) au lieu d'imposer la nôtre. Le
    // paramètre `q` avec le libellé donne une épingle nommée plutôt qu'un
    // point nu, ce qui aide à reconnaître l'adresse à l'arrivée.
    final label = Uri.encodeComponent(place.name);
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
  /// Nul sur une commande adhoc non réclamée : le serveur en retire les
  /// coordonnées tant que la course n'est pas acceptée.
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
