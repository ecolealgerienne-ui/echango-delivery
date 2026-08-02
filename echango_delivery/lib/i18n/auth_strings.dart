import 'dart:ui' show Locale;

import 'translate.dart';

/// Connexion et création de compte.
///
/// Les seuls écrans qu'un utilisateur voit **avant** d'avoir un profil : la
/// langue y est donc choisie sans qu'on sache encore à qui l'on parle, et c'est
/// exactement pourquoi le sélecteur de langue y est posé (29/07/2026).
String authLabel(String key, Locale locale, [Map<String, String>? vars]) =>
    translate(_fr, _ar, key, locale, vars);

/// Les deux tables, exposées pour le vérificateur de clés.
const Map<String, Map<String, String>> authLabelTables = {'fr': _fr, 'ar': _ar};

const Map<String, String> _fr = {
  // ── Connexion ───────────────────────────────────────────────────────────
  'auth.login.email': 'Email',
  'auth.login.password': 'Mot de passe',
  'auth.login.submit': 'Se connecter',
  'auth.login.missing': 'Renseigner l’email et le mot de passe',
  'auth.login.register': 'Créer un compte commerçant',
  // Dit pourquoi il n'y a pas de bouton « créer un compte transporteur » :
  // sans cette phrase, son absence se lit comme un défaut de l'application.
  'auth.login.driver_note': 'Les accès transporteur sont créés par Echango.',
  'auth.login.open_as': 'Ouvrir en tant que',
  'auth.login.dev_accounts': 'Comptes de test (debug)',

  // ── Inscription ─────────────────────────────────────────────────────────
  'auth.register.title': 'Créer un compte',
  // ── Le profil qu'on crée ────────────────────────────────────────────────
  //
  // ⚠️ Trois parcours, dont deux n'avaient AUCUN écran (revue du 01/08/2026,
  // A1) : `registerDriverWithInvitation` était écrite côté client sans le
  // moindre appelant, et `POST /auth/flotte/register` n'avait que des scripts.
  // Au pilote, un opérateur remettait un jeton d'invitation à un transporteur
  // qui n'avait nulle part où le saisir, et une entreprise ne pouvait pas
  // s'inscrire du tout — avec cinq lots d'écrans construits derrière.
  'auth.register.as': 'Je suis',
  'auth.register.as.merchant': 'Commerçant',
  'auth.register.as.fleet': 'Entreprise de transport',
  'auth.register.as.driver': 'Transporteur',
  'auth.register.fleet.name': 'Nom de l’entreprise *',
  'auth.register.fleet.name.hint': 'Affiché aux commerçants',
  'auth.register.driver.name': 'Prénom',
  'auth.register.driver.lastname': 'Nom',
  'auth.register.invitation': 'Code d’invitation *',
  // La consigne dit d'où vient le code, parce qu'un transporteur qui ne l'a pas
  // n'a aucun moyen de le deviner — et qu'il n'existe pas d'auto-inscription.
  'auth.register.invitation.hint':
      'Remis par Echango ou par votre entreprise de transport.',
  'auth.register.missing.fleet': 'Nom de l’entreprise, email et mot de passe sont requis',
  'auth.register.missing.driver': 'Code d’invitation, email et mot de passe sont requis',
  // Ce n'est pas une erreur : la demande est enregistrée, l'accès attend une
  // validation. L'afficher en rouge, comme avant, faisait lire une inscription
  // réussie comme un échec.
  'auth.register.pending.title': 'Demande enregistrée',

  'auth.register.missing': 'Commerce, email et mot de passe sont requis',
  'auth.register.password.short':
      'Le mot de passe doit faire au moins {n} caractères',
  'auth.register.name': 'Nom du commerce *',
  'auth.register.name.hint': 'Affiché aux transporteurs',
  'auth.register.email': 'Email *',
  'auth.register.password': 'Mot de passe *',
  'auth.register.password.hint': '{n} caractères minimum',
  'auth.register.phone': 'Téléphone',
  'auth.register.submit': 'Créer le compte',
};

const Map<String, String> _ar = {
  // ── Connexion ───────────────────────────────────────────────────────────
  'auth.login.email': 'البريد الإلكتروني',
  'auth.login.password': 'كلمة المرور',
  'auth.login.submit': 'تسجيل الدخول',
  'auth.login.missing': 'أدخل البريد الإلكتروني وكلمة المرور',
  'auth.login.register': 'إنشاء حساب تاجر',
  'auth.login.driver_note': 'حسابات الناقلين تُنشئها Echango.',
  'auth.login.open_as': 'الدخول بصفة',
  'auth.login.dev_accounts': 'حسابات تجريبية (تصحيح)',

  // ── Inscription ─────────────────────────────────────────────────────────
  'auth.register.title': 'إنشاء حساب',
  'auth.register.as': 'أنا',
  'auth.register.as.merchant': 'تاجر',
  'auth.register.as.fleet': 'شركة نقل',
  'auth.register.as.driver': 'ناقل',
  'auth.register.fleet.name': 'اسم الشركة *',
  'auth.register.fleet.name.hint': 'يظهر للتجار',
  'auth.register.driver.name': 'الاسم',
  'auth.register.driver.lastname': 'اللقب',
  'auth.register.invitation': 'رمز الدعوة *',
  'auth.register.invitation.hint': 'يُسلَّم من إيشانغو أو من شركة النقل التابع لها.',
  'auth.register.missing.fleet': 'اسم الشركة والبريد وكلمة المرور مطلوبة',
  'auth.register.missing.driver': 'رمز الدعوة والبريد وكلمة المرور مطلوبة',
  'auth.register.pending.title': 'تم تسجيل الطلب',

  'auth.register.missing': 'اسم المتجر والبريد وكلمة المرور مطلوبة',
  'auth.register.password.short':
      'يجب أن تتكون كلمة المرور من {n} أحرف على الأقل',
  'auth.register.name': 'اسم المتجر *',
  'auth.register.name.hint': 'يظهر للناقلين',
  'auth.register.email': 'البريد الإلكتروني *',
  'auth.register.password': 'كلمة المرور *',
  'auth.register.password.hint': '{n} أحرف على الأقل',
  'auth.register.phone': 'الهاتف',
  'auth.register.submit': 'إنشاء الحساب',
};
