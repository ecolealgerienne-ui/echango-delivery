import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';

import '../errors/error_message.dart';

/// L'enveloppe d'une écriture : drapeau d'attente, erreur traduite, relecture.
///
/// ── Pourquoi elle existe ──────────────────────────────────────────────────
///
/// Cinq classes d'état la portaient chacune en propre — `AuthState._run`,
/// `CashState._mutate`, `MerchantOrderState._addressWrite` et `._orderWrite`,
/// `OrderState._mutateOrder` — **identiques à 90-98 %** selon le détecteur de
/// corps similaires. Elles ne différaient que par la relecture déclenchée après
/// l'action.
///
/// ⚠️ **J'avais conclu le 31/07 qu'il ne fallait pas les fusionner**, au motif
/// qu'un mixin devrait accéder aux champs privés de quatre classes. C'était la
/// bonne objection à la mauvaise solution : le mixin n'a pas besoin des champs,
/// il a besoin de **savoir les écrire**. Trois membres d'une ligne par classe
/// suffisent, et les cent-neuf autres références à `_isLoading` /
/// `_errorMessage` ne bougent pas.
///
/// ── Ce que l'enveloppe garantit, et qui se perdait à la recopie ───────────
///
/// 1. `notifyListeners()` est appelé **deux fois** — au début et dans le
///    `finally`. Une copie qui oublie le second laisse l'écran en attente pour
///    toujours après un échec.
/// 2. L'erreur passe par `messageForError`, donc par le registre de codes : un
///    `catch` qui poserait `e.toString()` afficherait un message technique en
///    anglais à un utilisateur arabophone (règle 4).
/// 3. Le drapeau retombe dans le `finally`, **même sur exception**.
/// 4. La relecture est optionnelle mais **suit l'action**, jamais l'inverse :
///    relire avant d'écrire rendrait l'état d'avant.
mixin WriteEnvelope on ChangeNotifier {
  /// Écrit le drapeau d'attente de la classe. Une ligne à implémenter.
  set busy(bool value);

  /// Écrit le message d'erreur de la classe. Une ligne à implémenter.
  set failure(String? value);

  /// La langue courante, pour traduire le code d'erreur du serveur.
  Locale get writeLocale;

  /// Exécute [action], puis [reload] si elle est fournie.
  ///
  /// Rend `true` si tout a abouti. En cas d'échec, l'erreur est déjà traduite
  /// et posée sur la classe — l'appelant n'a qu'à rendre `false` à son écran.
  Future<bool> runWrite(
    Future<void> Function() action, {
    Future<void> Function()? reload,
  }) async {
    busy = true;
    failure = null;
    _notify();
    try {
      await action();
      if (reload != null) await reload();
      return true;
    } catch (e) {
      failure = messageForError(e, writeLocale);
      return false;
    } finally {
      busy = false;
      _notify();
    }
  }

  // ── Ne pas notifier une classe déjà détruite (02/08/2026) ─────────────────

  bool _writeDisposed = false;

  /// ⚠️ **Une écriture survit à l'écran qui l'a lancée, et le `finally` le
  /// découvrait trop tard.**
  ///
  /// `runWrite` notifie **deux fois**, dont une dans un `finally` qui s'exécute
  /// après l'aller-retour réseau. Si la classe d'état a été détruite entre-temps
  /// — déconnexion, retour arrière, fin d'un parcours — ce second appel lève
  /// « A OrderState was used after being disposed ».
  ///
  /// Trouvé par le parcours transporteur joué dans l'application : les
  /// assertions passaient, et l'exception tombait **après** la fin du test,
  /// faisant sortir le processus en erreur sur un scénario réussi. En usage
  /// réel, c'est le transporteur qui accepte une course puis quitte l'écran
  /// avant que le serveur ait répondu — le geste le plus banal qui soit sur une
  /// connexion lente.
  ///
  /// Le garde vit dans le mixin, donc **une fois pour les quatre classes**
  /// d'état : le poser chez chacune serait exactement la duplication que cette
  /// enveloppe existe pour supprimer.
  void _notify() {
    if (_writeDisposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _writeDisposed = true;
    super.dispose();
  }
}
