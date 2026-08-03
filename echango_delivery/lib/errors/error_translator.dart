import 'dart:ui' show Locale;

/// Traduit un [code] d'erreur (voir `app_error.dart`) vers un message
/// affichable, en français ou en arabe.
///
/// ── Pourquoi une traduction par code, et pas le message du serveur ────────
///
/// Le BFF renvoie déjà un `message` en français à chaque erreur — mais c'est
/// un détail de log, pas un texte destiné à un utilisateur arabophone. Le
/// `code`, lui, est stable et couvert ici dans les deux langues cibles
/// (CLAUDE.md, 29/07/2026). Afficher `message` directement aurait mélangé les
/// langues à l'écran dès que l'app tourne en arabe.
///
/// ── Ce qui arrive quand un code manque ici ──────────────────────────────
///
/// Le message générique de la langue courante, jamais le texte français brut
/// — un défaut silencieux (l'utilisateur perd le détail du motif) est
/// préférable à un défaut visible (une phrase dans la mauvaise langue au
/// milieu d'un écran traduit). `error-codes.ts` (BFF) et `app_error.dart`
/// sont tenus à la main, sans partage de type entre les deux dépôts : cette
/// table est le seul endroit qui peut révéler l'écart, jamais le compilateur.
String translateErrorCode(String code, Locale locale) {
  final table = locale.languageCode == 'ar' ? _ar : _fr;
  return table[code] ?? _generic(locale);
}

String _generic(Locale locale) => locale.languageCode == 'ar'
    ? 'حدث خطأ. حاول مرة أخرى.'
    : 'Une erreur est survenue. Réessayez.';

const Map<String, String> _fr = {
  // ── Authentification ────────────────────────────────────────────────────
  'auth.invalid_credentials': 'Email ou mot de passe incorrect.',
  'auth.email_taken': 'Cette adresse email est déjà utilisée.',
  'merchant_pending':
      'Votre compte commerçant est en attente de validation par Echango.',
  'auth.merchant_not_found': 'Aucun compte commerçant ne correspond.',
  'auth.merchant_registration_failed': 'Inscription impossible pour le moment.',
  'auth.fleet_registration_failed': 'Inscription impossible pour le moment.',
  'fleet_pending':
      'Votre entreprise est en attente de validation par Echango.',
  'auth.driver_not_in_fleet':
      "Ce transporteur n'appartient pas à votre entreprise.",
  'auth.driver_registration_failed': 'Inscription impossible pour le moment.',
  'auth.driver_not_found': 'Ce transporteur est introuvable.',
  'auth.driver_unknown': 'Invitation invalide : transporteur inconnu.',
  'auth.driver_already_linked': 'Ce transporteur a déjà un compte lié.',
  'auth.driver_already_has_account': 'Ce transporteur a déjà un compte.',
  'auth.driver_invitation_failed': 'Envoi de l\'invitation impossible.',
  'auth.invitation_invalid': 'Ce lien d\'invitation n\'est plus valide.',
  'auth.token_invalid': 'Session invalide ou expirée, reconnectez-vous.',
  'auth.missing_token': 'Session invalide, reconnectez-vous.',
  'auth.session_revoked': 'Session révoquée, reconnectez-vous.',

  // ── Encaissement à la porte ─────────────────────────────────────────────
  //
  // ⚠️ Vingt-cinq entrées ont disparu le 03/08/2026 avec le registre de caisse
  // (`docs/registre_caisse_precis.md`). Les cinq restantes portent sur le seul
  // geste qui subsiste : déclarer ce qui a été perçu en clôturant.
  'merchant.fleet_not_in_network':
      'Cette entreprise ne fait pas partie du réseau Echango.',
  'cash.cod_declaration_required':
      'Cette livraison est payée à la réception : déclarez le montant '
          'encaissé pour la clôturer.',
  'cash.amount_negative': 'Le montant ne peut pas être négatif.',
  'cash.amount_exceeds_expected': 'Le montant dépasse celui attendu.',
  'cash.discrepancy_reason_required':
      'Indiquez la raison de l’écart avec le montant attendu.',
  'cash.collection_not_recorded':
      'L’encaissement n’a pas pu être enregistré. Ne clôturez pas cette '
          'livraison : réessayez dans un instant.',

  // ── Commandes ────────────────────────────────────────────────────────────
  'order.not_found': 'Commande introuvable.',
  'order.forbidden': 'Vous n\'avez pas accès à cette commande.',
  'order.fetch_failed': 'Impossible de récupérer les commandes.',
  'order.assign_failed': 'Attribution de la commande impossible.',
  'order.create_failed': 'Création de la livraison impossible. Réessayez.',
  'order.cancel_failed': 'Annulation de la commande impossible.',
  'order.cancel_not_allowed':
      'Le transporteur est déjà en route. Contactez Echango pour annuler.',
  'order.already_terminal': 'Cette commande est déjà terminée.',
  'order.already_started': 'Cette course est déjà démarrée.',
  'order.already_accepted': 'Cette course a déjà été acceptée.',
  'order.already_declined': 'Cette course a déjà été refusée.',
  'order.not_assigned_to_driver': 'Cette course ne vous est pas assignée.',
  'order.decline_reason_required': 'Indiquez un motif de refus.',
  'order.decline_not_recorded':
      'Votre refus n’a pas pu être enregistré. Réessayez dans un instant.',
  'order.failure_not_recorded':
      'Votre signalement n’a pas pu être enregistré. Réessayez dans un instant.',
  'order.proof_required': 'Une preuve de livraison est requise.',
  'order.proof_not_found': 'Aucune preuve disponible pour cette commande.',
  'order.tracking_failed': 'Suivi de la commande indisponible.',
  'order.template_failed': 'Impossible de relire cette commande pour l\'instant.',
  'order.missing_public_id': 'Commande mal formée côté serveur.',
  'order.release_failed': 'Impossible de rendre cette course pour l\'instant.',
  'order.already_taken': 'Cette course vient d\'être prise par un autre transporteur.',
  'order.claim_failed': 'Impossible de prendre cette course pour le moment.',
  'order.cod_requires_price':
      'Indiquez la rémunération du transporteur : elle sera réclamée au destinataire en plus de la marchandise.',
  'order.custom_fields_unavailable':
      'Enregistrement impossible pour le moment. Réessayez dans un instant.',
  'order.already_published': 'Cette commande a déjà été publiée.',
  'order.publish_failed': 'Impossible de publier cette commande pour le moment.',
  'order.accept_failed': 'Impossible d\'accepter cette course.',
  'order.start_failed': 'Impossible de démarrer cette course.',
  'order.complete_failed': 'Impossible de terminer cette course.',
  'order.activities_fetch_failed': 'Étapes de la course indisponibles.',
  'order.activity_update_failed': 'Mise à jour de l\'étape impossible.',
  'order.proof_upload_failed': 'Envoi de la preuve impossible.',
  'order.not_found_upstream': 'Commande introuvable chez le transporteur.',

  // ── Transporteurs ────────────────────────────────────────────────────────
  'driver.not_found': 'Transporteur introuvable.',
  'driver.forbidden': 'Accès refusé à ce transporteur.',
  'driver.fetch_failed': 'Impossible de récupérer les transporteurs.',
  'driver.create_failed': 'Création du transporteur impossible.',
  'driver.positions_fetch_failed': 'Positions des transporteurs indisponibles.',
  'driver.inactive': 'Compte transporteur introuvable ou inactif.',
  'driver.unavailable': 'Ce transporteur n\'est pas disponible.',
  'driver.public_id_unresolved': 'Transporteur mal identifié côté serveur.',
  'driver.position_update_failed': 'Envoi de la position impossible.',
  'driver.online_toggle_failed': 'Changement de disponibilité impossible.',
  'driver.search_unavailable': 'Recherche indisponible pour le moment.',
  'driver.search_too_broad':
      'Trop de résultats — précisez le nom ou le numéro de téléphone.',
  'driver.already_in_network':
      'Cette personne est déjà dans le réseau. Recherchez-la et demandez son '
          'rattachement au lieu de la créer.',
  'membership.not_found': 'Ce rattachement n’existe pas.',
  'membership.already_exists': 'Une demande existe déjà pour ce conducteur.',
  'membership.not_pending': 'Cette demande a déjà reçu une réponse.',
  'membership.not_active': 'Seul un rattachement actif peut être suspendu.',
  'membership.not_suspended': 'Seul un rattachement suspendu peut être réactivé.',

  // ── Flotte (persona petite flotte) ──────────────────────────────────────
  'fleet.not_found': 'Compte flotte introuvable.',
  'fleet.inactive': 'Compte flotte inactif.',

  // ── Commerçant ───────────────────────────────────────────────────────────
  'merchant.not_found': 'Compte commerçant introuvable.',
  'merchant.inactive': 'Compte commerçant inactif.',
  'merchant.address_not_found': 'Adresse introuvable.',
  'merchant.favourite_not_found': 'Favori introuvable.',
  'merchant.favourite_already_exists': 'Ce transporteur est déjà en favori.',
  'merchant.driver_not_in_network': 'Ce transporteur n\'existe pas dans le réseau Echango.',
  'merchant.favourite_add_unavailable': 'Ajout du favori impossible pour le moment.',
  'merchant.address_save_failed': 'Enregistrement de l\'adresse impossible.',
  'merchant.address_update_failed': 'Modification de l\'adresse impossible.',
  'merchant.address_delete_failed': 'Suppression de l\'adresse impossible.',

  // ── Signalements et notifications ───────────────────────────────────────
  'notification.not_found': 'Notification introuvable.',

  // ── Géocodage ────────────────────────────────────────────────────────────
  'geocoding.unavailable': 'Recherche d\'adresse indisponible.',

  // ── Validation générique ─────────────────────────────────────────────────
  'validation.invalid_id': 'Identifiant invalide.',
  'validation.failed': 'Certaines informations saisies sont invalides.',

  // ── Erreurs serveur / techniques ─────────────────────────────────────────
  'server.schema_out_of_sync': 'Erreur technique, réessayez.',
  'server.invalid_profile_type': 'Profil non reconnu.',
  'server.persona_forbidden': 'Cette action n\'est pas autorisée pour votre profil.',
  'merchant.addresses_unavailable':
      'Impossible de lire votre carnet d’adresses. Réessayez dans un instant.',
  'merchant.known_drivers_unavailable':
      'Impossible de lire vos transporteurs habituels.',
  'server.unexpected':
      'Le serveur a rencontré un problème. Réessayez dans un instant.',

  // ── Constats du client, sans contrepartie serveur ───────────────────────
  'network.error': 'Connexion au serveur impossible. Vérifiez votre réseau.',
  'server.error': 'Le serveur a rencontré une erreur. Réessayez.',
  'timeout.error': 'Le serveur met trop de temps à répondre. Réessayez.',
  'not_found': 'Ressource introuvable.',
  'error.unknown': 'Une erreur est survenue. Réessayez.',
  'location.permission_denied':
      'Autorisez la localisation pour recevoir des courses : les courses '
          'sont attribuées selon votre position.',
  'location.foreground_service_denied':
      'Sans autorisation de notification, le partage de position s\'arrêtera '
          'dès que vous quitterez l\'application.',
  'photo.camera_unavailable':
      'Impossible d\'ouvrir l\'appareil photo. Vérifiez l\'autorisation caméra '
          'dans les réglages.',
  'photo.empty': 'La photo est vide, réessayez.',
  'photo.too_large':
      'Photo trop volumineuse ({size} Mo). Reprenez-la de plus loin ou avec '
          'une résolution plus basse.',
  'client.fleet_profile_unavailable':
      'Le profil gestionnaire de flotte n\'est pas encore disponible dans '
          'l\'application.',
  'client.multiple_profiles_match':
      'Plusieurs profils correspondent à cet identifiant. Choisissez celui à '
          'ouvrir.',
};

const Map<String, String> _ar = {
  // ── المصادقة ─────────────────────────────────────────────────────────────
  'auth.invalid_credentials': 'البريد الإلكتروني أو كلمة المرور غير صحيحة.',
  'auth.email_taken': 'هذا البريد الإلكتروني مستخدم بالفعل.',
  'merchant_pending': 'حساب التاجر الخاص بك في انتظار موافقة Echango.',
  'auth.merchant_not_found': 'لا يوجد حساب تاجر مطابق.',
  'auth.merchant_registration_failed': 'التسجيل غير ممكن حالياً.',
  'auth.fleet_registration_failed': 'التسجيل غير ممكن حالياً.',
  'fleet_pending': 'شركتك في انتظار موافقة Echango.',
  'auth.driver_not_in_fleet': 'هذا السائق لا ينتمي إلى شركتك.',
  'auth.driver_registration_failed': 'التسجيل غير ممكن حالياً.',
  'auth.driver_not_found': 'هذا السائق غير موجود.',
  'auth.driver_unknown': 'دعوة غير صالحة: سائق غير معروف.',
  'auth.driver_already_linked': 'هذا السائق لديه حساب مرتبط بالفعل.',
  'auth.driver_already_has_account': 'هذا السائق لديه حساب بالفعل.',
  'auth.driver_invitation_failed': 'تعذر إرسال الدعوة.',
  'auth.invitation_invalid': 'رابط الدعوة هذا لم يعد صالحاً.',
  'auth.token_invalid': 'الجلسة غير صالحة أو منتهية، يرجى تسجيل الدخول مجدداً.',
  'auth.missing_token': 'جلسة غير صالحة، يرجى تسجيل الدخول مجدداً.',
  'auth.session_revoked': 'تم إلغاء الجلسة، يرجى تسجيل الدخول مجدداً.',

  // ── التحصيل عند الباب ────────────────────────────────────────────────────
  'merchant.fleet_not_in_network': 'هذه الشركة ليست ضمن شبكة Echango.',
  'cash.cod_declaration_required':
      'هذه الطلبية تُدفع عند الاستلام: يرجى تصريح المبلغ المحصّل لإغلاقها.',
  'cash.amount_negative': 'لا يمكن أن يكون المبلغ سالباً.',
  'cash.amount_exceeds_expected': 'المبلغ يتجاوز المبلغ المتوقع.',
  'cash.discrepancy_reason_required': 'يرجى توضيح سبب الفرق في المبلغ المتوقع.',
  'cash.collection_not_recorded':
      'تعذّر تسجيل التحصيل. لا تُغلق عملية التسليم هذه: أعد المحاولة بعد لحظات.',

  // ── الطلبيات ──────────────────────────────────────────────────────────────
  'order.not_found': 'الطلبية غير موجودة.',
  'order.forbidden': 'ليس لديك صلاحية الوصول إلى هذه الطلبية.',
  'order.fetch_failed': 'تعذر جلب الطلبيات.',
  'order.assign_failed': 'تعذر إسناد الطلبية.',
  'order.create_failed': 'تعذر إنشاء التوصيل. حاول مرة أخرى.',
  'order.cancel_failed': 'تعذر إلغاء الطلبية.',
  'order.cancel_not_allowed':
      'السائق في الطريق بالفعل. يرجى التواصل مع Echango لإلغاء التوصيل.',
  'order.already_terminal': 'هذه الطلبية منتهية بالفعل.',
  'order.already_started': 'هذه الرحلة بدأت بالفعل.',
  'order.already_accepted': 'تم قبول هذه الرحلة بالفعل.',
  'order.already_declined': 'تم رفض هذه الرحلة بالفعل.',
  'order.not_assigned_to_driver': 'هذه الرحلة غير مسندة إليك.',
  'order.decline_reason_required': 'يرجى تحديد سبب الرفض.',
  'order.decline_not_recorded':
      'تعذّر تسجيل رفضك. أعد المحاولة بعد لحظات.',
  'order.failure_not_recorded':
      'تعذّر تسجيل بلاغك. أعد المحاولة بعد لحظات.',
  'order.proof_required': 'إثبات التسليم مطلوب.',
  'order.proof_not_found': 'لا يوجد إثبات متاح لهذه الطلبية.',
  'order.tracking_failed': 'تتبع الطلبية غير متاح.',
  'order.template_failed': 'تعذرت قراءة هذه الطلبية حالياً.',
  'order.missing_public_id': 'خطأ في تكوين الطلبية على الخادم.',
  'order.release_failed': 'تعذر إعادة هذه الرحلة حالياً.',
  'order.already_taken': 'تم أخذ هذه الرحلة من قبل سائق آخر.',
  'order.claim_failed': 'لا يمكن أخذ هذه الرحلة في الوقت الحالي.',
  'order.cod_requires_price':
      'حدّد أجرة الناقل: ستُطلب من المستلم إضافةً إلى ثمن البضاعة.',
  'order.custom_fields_unavailable':
      'تعذّر الحفظ في الوقت الحالي. أعد المحاولة بعد قليل.',
  'order.already_published': 'تم نشر هذه الطلبية بالفعل.',
  'order.publish_failed': 'تعذر نشر هذه الطلبية حالياً.',
  'order.accept_failed': 'تعذر قبول هذه الرحلة.',
  'order.start_failed': 'تعذر بدء هذه الرحلة.',
  'order.complete_failed': 'تعذر إنهاء هذه الرحلة.',
  'order.activities_fetch_failed': 'خطوات الرحلة غير متاحة.',
  'order.activity_update_failed': 'تعذر تحديث الخطوة.',
  'order.proof_upload_failed': 'تعذر إرسال الإثبات.',
  'order.not_found_upstream': 'الطلبية غير موجودة لدى مزوّد الخدمة.',

  // ── السائقون ──────────────────────────────────────────────────────────────
  'driver.not_found': 'السائق غير موجود.',
  'driver.forbidden': 'الوصول مرفوض لهذا السائق.',
  'driver.fetch_failed': 'تعذر جلب السائقين.',
  'driver.create_failed': 'تعذر إنشاء السائق.',
  'driver.positions_fetch_failed': 'مواقع السائقين غير متاحة.',
  'driver.inactive': 'حساب السائق غير موجود أو غير نشط.',
  'driver.unavailable': 'هذا السائق غير متاح.',
  'driver.public_id_unresolved': 'خطأ في تعريف السائق على الخادم.',
  'driver.position_update_failed': 'تعذر إرسال الموقع.',
  'driver.online_toggle_failed': 'تعذر تغيير حالة التوفر.',
  'driver.search_unavailable': 'البحث غير متاح حالياً.',
  'driver.search_too_broad': 'نتائج كثيرة — حدّد الاسم أو رقم الهاتف.',
  'driver.already_in_network':
      'هذا الشخص موجود بالفعل في الشبكة. ابحث عنه واطلب ربطه بدل إنشائه من جديد.',
  'membership.not_found': 'هذا الارتباط غير موجود.',
  'membership.already_exists': 'يوجد طلب سابق لهذا السائق.',
  'membership.not_pending': 'تمت الإجابة على هذا الطلب من قبل.',
  'membership.not_active': 'يمكن تعليق الارتباط المفعّل فقط.',
  'membership.not_suspended': 'يمكن إعادة تفعيل الارتباط المعلّق فقط.',

  // ── الأسطول (ملف مدير الأسطول الصغير) ────────────────────────────────────
  'fleet.not_found': 'حساب الأسطول غير موجود.',
  'fleet.inactive': 'حساب الأسطول غير نشط.',

  // ── التاجر ────────────────────────────────────────────────────────────────
  'merchant.not_found': 'حساب التاجر غير موجود.',
  'merchant.inactive': 'حساب التاجر غير نشط.',
  'merchant.address_not_found': 'العنوان غير موجود.',
  'merchant.favourite_not_found': 'السائق المفضل غير موجود.',
  'merchant.favourite_already_exists': 'هذا السائق مضاف بالفعل إلى المفضلة.',
  'merchant.driver_not_in_network': 'هذا السائق غير موجود في شبكة Echango.',
  'merchant.favourite_add_unavailable': 'تعذرت إضافة السائق المفضل حالياً.',
  'merchant.address_save_failed': 'تعذر حفظ العنوان.',
  'merchant.address_update_failed': 'تعذر تعديل العنوان.',
  'merchant.address_delete_failed': 'تعذر حذف العنوان.',

  // ── الإشعارات ─────────────────────────────────────────────────────────────
  'notification.not_found': 'الإشعار غير موجود.',

  // ── تحديد المواقع ─────────────────────────────────────────────────────────
  'geocoding.unavailable': 'البحث عن العنوان غير متاح.',

  // ── التحقق من الصحة ───────────────────────────────────────────────────────
  'validation.invalid_id': 'معرّف غير صالح.',
  'validation.failed': 'بعض المعلومات المدخلة غير صالحة.',

  // ── أخطاء الخادم / التقنية ────────────────────────────────────────────────
  'server.schema_out_of_sync': 'خطأ تقني، يرجى المحاولة مرة أخرى.',
  'server.invalid_profile_type': 'الملف الشخصي غير معروف.',
  'server.persona_forbidden': 'هذا الإجراء غير مسموح به لملفك الشخصي.',
  'merchant.addresses_unavailable':
      'تعذّرت قراءة دفتر عناوينك. أعد المحاولة بعد لحظات.',
  'merchant.known_drivers_unavailable':
      'تعذّرت قراءة قائمة ناقليك المعتادين.',
  'server.unexpected': 'واجه الخادم مشكلة. أعد المحاولة بعد لحظات.',

  // ── ملاحظات جهاز العميل، بدون رمز من الخادم ──────────────────────────────
  'network.error': 'تعذر الاتصال بالخادم. تحقق من شبكتك.',
  'server.error': 'واجه الخادم خطأً. حاول مرة أخرى.',
  'timeout.error': 'استغرق الخادم وقتاً طويلاً للرد. حاول مرة أخرى.',
  'not_found': 'المورد غير موجود.',
  'error.unknown': 'حدث خطأ. حاول مرة أخرى.',
  'location.permission_denied':
      'يرجى السماح بتحديد الموقع لاستقبال الرحلات: يتم إسناد الرحلات حسب موقعك.',
  'location.foreground_service_denied':
      'بدون إذن الإشعارات، سيتوقف مشاركة الموقع بمجرد مغادرة التطبيق.',
  'photo.camera_unavailable': 'تعذر فتح الكاميرا. تحقق من إذن الكاميرا في الإعدادات.',
  'photo.empty': 'الصورة فارغة، حاول مرة أخرى.',
  'photo.too_large':
      'الصورة كبيرة جداً ({size} ميغابايت). أعد التقاطها من بعيد أو بدقة أقل.',
  'client.fleet_profile_unavailable':
      'ملف مدير الأسطول غير متاح بعد في التطبيق.',
  'client.multiple_profiles_match':
      'عدة ملفات شخصية تطابق هذا المعرّف. اختر الملف الذي تريد فتحه.',
};
