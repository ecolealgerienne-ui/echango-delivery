import 'package:flutter/material.dart';

import '../i18n/order_strings.dart';

/// Catégories de véhicule, partagées par les deux profils.
///
/// La même liste sert au commerçant (ce qu'il exige) et au transporteur (ce
/// qu'il conduit) : deux copies auraient fini par diverger, et un écart entre
/// les deux se traduirait par des courses jamais proposées à personne.
///
/// L'ordre est significatif : c'est une **échelle de capacité**. Une exigence
/// est un minimum, pas une égalité — demander une voiture n'écarte pas un
/// utilitaire. Le serveur applique la même règle.
const vehicleLadder = ['moto', 'voiture', 'utilitaire'];

IconData vehicleIcon(String? type) => switch (type) {
      'moto' => Icons.two_wheeler_outlined,
      'voiture' => Icons.directions_car_outlined,
      'utilitaire' => Icons.local_shipping_outlined,
      _ => Icons.help_outline,
    };

/// Le nom du véhicule, dans la langue courante.
///
/// ⚠️ **La locale est exigée**, pour la raison déjà retenue pour
/// `formatRelative` et `orderStatusLabel` : un paramètre facultatif valant
/// français aurait laissé chaque nouvel appelant introduire un mot français
/// dans un écran arabe sans que personne relise. C'est exactement ce qui s'est
/// produit ici — l'unique appelant compose `'{vehicle} على الأقل'`, donc un
/// commerçant arabophone lisait « Moto على الأقل ».
String vehicleLabel(String? type, Locale locale) => orderLabel(
      switch (type) {
        'moto' => 'order.vehicle.moto',
        'voiture' => 'order.vehicle.voiture',
        'utilitaire' => 'order.vehicle.utilitaire',
        _ => 'order.vehicle.any',
      },
      locale,
    );
