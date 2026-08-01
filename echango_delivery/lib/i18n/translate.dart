import 'dart:ui' show Locale;

/// La lecture d'une table de libellés — **écrite une fois pour les six**.
///
/// ── Pourquoi ce fichier existe ────────────────────────────────────────────
///
/// Les six tables (`order`, `fleet`, `cash`, `driver`, `auth`, `common`)
/// portaient chacune sa propre fonction d'accès, **identiques à 100 %** :
/// choisir la table selon la langue, retomber sur le français, substituer les
/// `{variable}`. Six copies de dix lignes, créées le même jour, par le même
/// geste — et le détecteur de corps similaires les a désignées avant que la
/// première divergence n'arrive.
///
/// Le critère de la règle 5 ne laisse aucun doute : **si l'une change, les six
/// doivent changer.** Le jour où il faudra une pluralisation, un repli sur une
/// troisième langue ou un journal des clés manquantes, une copie oubliée ne
/// produirait aucune erreur — seulement un écran qui se comporte autrement que
/// les autres.
///
/// ── Les deux règles que la fonction porte ─────────────────────────────────
///
/// 1. **Repli sur le français, puis sur la clé** — jamais sur une chaîne vide.
///    Une clé à l'écran est laide et se corrige ; une phrase française au
///    milieu d'un écran arabe passe pour un défaut de l'application, et un
///    libellé vide pour un écran cassé.
/// 2. **Substitution par `{nom}`** plutôt que par concaténation : l'ordre des
///    mots change d'une langue à l'autre, et c'est ce qui rend une conversion
///    prouvable par resubstitution.
String translate(
  Map<String, String> fr,
  Map<String, String> ar,
  String key,
  Locale locale, [
  Map<String, String>? vars,
]) {
  final table = locale.languageCode == 'ar' ? ar : fr;
  var value = table[key] ?? fr[key] ?? key;

  if (vars != null) {
    for (final entry in vars.entries) {
      value = value.replaceAll('{${entry.key}}', entry.value);
    }
  }
  return value;
}
