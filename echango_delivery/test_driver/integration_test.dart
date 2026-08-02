/// Le lanceur de `flutter drive`.
///
/// Il ne contient aucune logique et n'en contiendra jamais : tout ce qui est
/// vérifié vit dans `integration_test/`, qui s'exécute **sur l'appareil**. Ce
/// fichier-ci tourne sur la machine de développement et ne fait que relayer le
/// verdict. Les deux moitiés ne partagent pas de mémoire — y écrire une
/// assertion la rendrait aveugle à ce qui se passe à l'écran.
library;

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
