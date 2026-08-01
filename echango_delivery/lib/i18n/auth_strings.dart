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
