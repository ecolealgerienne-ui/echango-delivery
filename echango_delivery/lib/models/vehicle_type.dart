import 'package:flutter/material.dart';

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

String vehicleLabel(String? type) => switch (type) {
      'moto' => 'Moto',
      'voiture' => 'Voiture',
      'utilitaire' => 'Utilitaire',
      _ => 'Indifférent',
    };
