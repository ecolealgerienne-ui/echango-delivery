import 'dart:ui' show Locale;

import 'translate.dart';

/// Libellés du formulaire de demande de livraison (commerçant).
///
/// ── Pourquoi cet écran en premier ─────────────────────────────────────────
///
/// C'est le plus gros du lot (85 chaînes visibles) et **c'est là qu'on saisit
/// ce qui engage de l'argent** : le montant réclamé au destinataire, la
/// rémunération du transporteur, et qui paie la livraison. Un commerçant
/// arabophone lisait ici, en français, la différence entre « Montant à
/// encaisser » et « Prix de la marchandise » — deux intitulés qui ne désignent
/// le même nombre que dans un cas sur deux, et dont la confusion se constate à
/// la porte, en espèces.
///
/// ── Le mécanisme, repris de `cash_strings.dart` ──────────────────────────
///
/// Deux tables, une par langue, clés strictement identiques
/// (`tool/check_error_codes.dart` le vérifie), et des `{variable}` plutôt que
/// des concaténations : l'ordre des mots change d'une langue à l'autre, et
/// surtout **la conversion se prouve** — chaque chaîne retirée de l'écran doit
/// se retrouver dans la table, placeholders resubstitués. C'est la seule façon
/// de relire quatre-vingts remplacements sans analyseur.
///
/// Un libellé manquant retombe sur sa clé plutôt que sur du français brut : une
/// clé à l'écran est laide et se corrige, une phrase française au milieu d'un
/// écran arabe passe pour un défaut de l'application.
///
/// ⚠️ **Ce qui n'est PAS ici, et ne doit pas y venir** : `'Commerce'`, le repli
/// de `pickupContactName` à la création. Ce n'est pas un libellé, c'est une
/// **donnée** envoyée au serveur, stockée chez Fleetbase et relue par le
/// transporteur. La traduire ferait dépendre le contenu de la base de la langue
/// du téléphone qui a créé la commande, et un même commerçant produirait des
/// contacts nommés tantôt « Commerce », tantôt « متجر ».
///
/// ⚠️ **L'arabe est de ma main et n'a pas été relu par un locuteur.** Les
/// pluriels sont approximatifs (« favori(s) » n'a pas d'équivalent direct), et
/// le vocabulaire monétaire mériterait une passe. Le dire ici plutôt que
/// laisser croire à une traduction validée.
String orderLabel(String key, Locale locale, [Map<String, String>? vars]) =>
    translate(_fr, _ar, key, locale, vars);

/// Les deux tables, exposées pour le vérificateur de clés.
const Map<String, Map<String, String>> orderLabelTables = {
  'fr': _fr,
  'ar': _ar,
};

const Map<String, String> _fr = {
  // ── Titres et sections ──────────────────────────────────────────────────
  'order.form.title.new': 'Nouvelle livraison',
  'order.form.title.duplicate': 'Reprendre une livraison',
  'order.section.pickup': 'Retrait',
  'order.section.dropoff': 'Livraison',
  'order.section.parcel': 'Colis',
  'order.form.section.options': 'Options',

  // ── Champs ──────────────────────────────────────────────────────────────
  'order.form.pickup.name': 'Lieu de retrait *',
  'order.form.pickup.contact': 'Contact sur place',
  'order.form.dropoff.name': 'Destinataire *',
  'order.form.dropoff.contact': 'Contact (si différent)',
  // Partagés par les deux points : le même mot pour la même chose, sinon deux
  // clés à tenir accordées pour rien.
  'order.form.address': 'Adresse',
  'order.form.phone': 'Téléphone *',

  // ── Colis ───────────────────────────────────────────────────────────────
  'order.form.item.description': 'Contenu (ex. : gâteau, médicaments)',
  'order.form.item.quantity': 'Nombre de colis',
  'order.form.item.weight': 'Poids approximatif (kg)',
  'order.form.item.fragile': 'Contenu fragile',
  'order.form.item.fragile.hint':
      'Signalé au transporteur avant qu’il accepte la course.',

  // ── Position ────────────────────────────────────────────────────────────
  'order.form.location.book': 'Carnet',
  'order.form.location.pick': 'Placer sur la carte',
  'order.form.location.edit': 'Modifier le point',
  'order.form.location.unset': 'Position non définie',
  'order.form.location.set': 'Position définie ({lat}, {lng})',
  'order.form.map.pickup': 'Point de retrait',
  'order.form.map.dropoff': 'Point de livraison',

  // ── Véhicule ────────────────────────────────────────────────────────────
  'order.form.vehicle.label': 'Véhicule nécessaire',
  'order.form.vehicle.any': 'Indifférent',
  'order.form.vehicle.moto': 'Moto minimum',
  'order.form.vehicle.voiture': 'Voiture minimum',
  'order.form.vehicle.utilitaire': 'Utilitaire requis',

  // Le véhicule **nu**, sans « minimum ». Les clés `order.form.vehicle.*`
  // ci-dessus empaquettent l'exigence dans le libellé, ce qui convient à un
  // sélecteur mais pas à `order.detail.row.vehicle.value` ('{vehicle} minimum'),
  // qui compose la phrase lui-même. `vehicleLabel` servait ces quatre mots en
  // français uniquement, donc un écran arabe recevait « Moto » au milieu de
  // « {vehicle} على الأقل ».
  'order.vehicle.any': 'Indifférent',
  'order.vehicle.moto': 'Moto',
  'order.vehicle.voiture': 'Voiture',
  'order.vehicle.utilitaire': 'Utilitaire',

  // ── Ligne de colis ──────────────────────────────────────────────────────
  //
  // Le résumé « Gâteau · 2 kg · fragile » de `OrderItemLine.label`. Distinct de
  // `order.form.item.fragile` ('Contenu fragile'), qui est le libellé d'une
  // case à cocher : ici c'est une mention dans une énumération.
  'order.item.weight': '{weight} kg',
  'order.item.fragile': 'fragile',

  // ── Favoris : le repli quand la partie n'a pas de nom ────────────────────
  //
  // Une entreprise et un transporteur ne se nomment pas pareil quand le nom
  // manque : « Transporteur 3f2a… » sur une société serait faux, et le lecteur
  // n'aurait aucun moyen de le savoir.
  'order.party.driver.unnamed': 'Transporteur {id}',
  'order.party.fleet.unnamed': 'Entreprise {id}',

  // ── Tarification ────────────────────────────────────────────────────────
  'order.form.price.label': 'Rémunération proposée (DZD)',
  'order.form.price.hint':
      'Ce montant est affiché aux transporteurs : c’est sur lui qu’ils '
          'décident de prendre la course.',
  'order.form.price.hint.distance':
      'Distance estimée : {distance}. Ce montant est affiché aux transporteurs.',
  'order.form.quote.flat': 'Tarif Echango pour cette course',
  'order.form.quote.distance': 'Tarif Echango — {distance}',

  // ── Paiement à la livraison ─────────────────────────────────────────────
  'order.form.cod.enable': 'Le client paie à la livraison',
  'order.form.cod.enable.hint':
      'Le transporteur encaisse et vous remet la somme lors de son prochain '
          'passage. Echango ne détient jamais cet argent.',
  'order.form.cod.amount.total': 'Montant à encaisser (DZD)',
  'order.form.cod.amount.goods': 'Prix de la marchandise (DZD)',
  'order.form.cod.included': 'Les frais de livraison sont inclus',
  'order.form.cod.included.hint':
      'Le client règle la marchandise et la livraison en une fois.',
  'order.form.cod.excluded.hint':
      'Les frais de livraison sont réclamés au client en plus de la marchandise.',
  'order.form.cod.total.included': 'Le destinataire remettra {amount} DZD.',
  'order.form.cod.total.missing_fee':
      'Indiquez la rémunération du transporteur : elle sera réclamée au '
          'destinataire en plus de la marchandise.',
  'order.form.cod.total.excluded':
      'Le destinataire remettra {total} DZD ({goods} de marchandise + {fee} '
          'de livraison).',
  'order.form.cod.settlement':
      'Le transporteur retient sa rémunération sur les espèces et ne vous '
          'remet que la différence, lors de son prochain passage.',

  // ── Enlèvement ──────────────────────────────────────────────────────────
  'order.schedule.title': 'Enlèvement',
  'order.schedule.asap': 'Dès que possible',
  'order.form.schedule.clear': 'Revenir à « dès que possible »',

  // ── Preuve de livraison ─────────────────────────────────────────────────
  'order.pod.label': 'Preuve de livraison',
  'order.pod.photo': 'Photo à la livraison',
  'order.form.pod.none': 'Aucune preuve',

  // ── Favoris ─────────────────────────────────────────────────────────────
  'order.form.favourites.title':
      'Proposer d’abord à mes transporteurs habituels',
  'order.form.favourites.hint':
      '{count} favori(s). Si aucun n’est disponible, la course est proposée à '
          'l’ensemble du réseau.',
  'order.form.dispatch.label': 'À qui confier la course',
  'order.form.dispatch.large': 'Tout le réseau (diffusion large)',
  'order.form.dispatch.hint':
      'Un favori nommé reçoit la course rien que pour lui — elle l’attend même '
          'hors ligne. Vous pourrez toujours basculer en diffusion large.',

  // ── Instructions, brouillon, envoi ──────────────────────────────────────
  'order.form.instructions': 'Instructions pour le transporteur',
  'order.form.draft.notice':
      'Cette livraison est enregistrée en brouillon : aucun transporteur n’est '
          'sollicité tant que vous ne l’avez pas publiée depuis sa fiche.',
  'order.form.submit': 'Enregistrer en brouillon',

  // ── Carnet d'adresses (feuille) ─────────────────────────────────────────
  'order.form.book.search': 'Rechercher dans le carnet…',
  'order.form.book.empty': 'Aucune adresse ne correspond',

  // ── Messages ────────────────────────────────────────────────────────────
  'order.form.address.no_position':
      '« {name} » n’a pas de position enregistrée : placez-la sur la carte '
          'pour continuer.',
  'order.form.missing': 'Il manque {fields}',
  // Le séparateur est dans la table : l'arabe emploie sa propre virgule (،),
  // et un `', '` en dur produirait une énumération à la française au milieu
  // d'une phrase arabe.
  'order.form.missing.separator': ', ',
  'order.form.missing.pickup_name': 'le lieu de retrait',
  'order.form.missing.pickup_phone': 'le téléphone de retrait',
  'order.form.missing.dropoff_name': 'le nom du destinataire',
  'order.form.missing.dropoff_phone': 'le téléphone du destinataire',
  'order.form.missing.pickup_point': 'le point de retrait sur la carte',
  'order.form.missing.dropoff_point': 'le point de livraison sur la carte',
  // Bornes reproduites du serveur (`ServerRules`) : dites ici, champ nommé,
  // plutôt qu'attendues sous la forme d'un 400 générique.
  'order.form.invalid.price_max': 'le prix ne peut pas dépasser {max}',
  'order.form.invalid.cod_max':
      'le montant à encaisser ne peut pas dépasser {max}',
  'order.form.invalid.cod_min':
      'un encaissement de 0 se saisit en laissant le champ vide',
  'order.form.saved':
      'Brouillon enregistré. Relisez-le puis publiez-le pour trouver un '
          'transporteur.',
  'order.form.failed': 'Création impossible',

  // ── Fiche de livraison (commerçant) : actions ───────────────────────────
  'order.detail.title': 'Suivi de la livraison',
  'order.detail.not_found': 'Livraison introuvable',
  'order.detail.tracking': 'Numéro de suivi : {number}',
  'order.detail.created': 'Créée le {date}',
  'order.detail.publish': 'Publier',
  'order.detail.publish.done':
      'Livraison publiée : Echango recherche un transporteur.',
  'order.detail.publish.failed': 'Publication impossible',
  'order.detail.redirect': 'Rediriger la course',
  'order.detail.redirect.done': 'Course redirigée.',
  'order.detail.redirect.failed': 'Redirection impossible',
  'order.detail.duplicate': 'Refaire cette livraison',
  'order.detail.duplicate.failed':
      'Reprise impossible — le formulaire s’ouvre vide.',
  'order.detail.cancel.title': 'Annuler cette livraison ?',
  'order.detail.cancel.body':
      'La demande sera retirée. Cette action est définitive.',
  'order.detail.cancel.back': 'Retour',
  'order.detail.cancel.confirm': 'Annuler la livraison',
  'order.detail.cancel.done': 'Livraison annulée',
  'order.detail.cancel.failed': 'Annulation impossible',

  // ── Fiche de livraison : où ça en est ───────────────────────────────────
  'order.detail.state.draft':
      'Brouillon : aucun transporteur n’est sollicité tant que vous ne '
          'publiez pas cette livraison.',
  'order.detail.state.waiting':
      'En attente d’attribution. Echango recherche un transporteur disponible.',
  'order.detail.state.assigned':
      'Transporteur affecté. La course démarrera à l’enlèvement.',
  'order.detail.state.completed': 'Livraison effectuée.',
  'order.detail.state.cancelled': 'Livraison annulée.',

  // ── Fiche de livraison : le transporteur ────────────────────────────────
  'order.detail.driver.assigned': 'Pris en charge par {name}',
  'order.detail.driver.call': 'Appeler le transporteur',
  'order.detail.driver.call.short': 'Appeler',
  'order.detail.driver.position': 'Voir la position du transporteur',
  'order.detail.driver.position.none':
      'Position du transporteur non disponible pour le moment.',
  'order.detail.driver.position.unknown':
      'Dernière position connue, date inconnue',
  'order.detail.driver.position.seen': 'Position relevée {when}',
  'order.detail.refresh': 'Actualiser',

  // ── Fiche de livraison : l'argent ───────────────────────────────────────
  'order.detail.cash.title': 'Paiement à la livraison',
  'order.detail.cash.requested': 'Montant demandé : {amount}',
  'order.detail.cash.pending': 'Pas encore encaissé.',
  'order.detail.cash.collected': 'Perçu : {amount}',
  'order.detail.cash.held':
      'Cette somme est détenue par le transporteur jusqu’à sa remise. '
          'Suivez-la dans « Encaissements ».',
  // Le futur tant que rien n'est encaissé : c'est une projection, pas un solde.
  'order.detail.cash.will_return': 'Vous reviendra',
  'order.detail.cash.returns': 'Vous revient',
  'order.detail.cash.net': '{tense} : {amount}',
  'order.detail.cash.owed': 'Vous devrez au transporteur : {amount}',
  'order.detail.cash.settlement':
      'Le transporteur retient sa rémunération ({fee}) sur ce qu’il encaisse '
          'et vous remet la différence.',

  // ── Fiche de livraison : ce qui a été demandé ───────────────────────────
  'order.detail.request': 'Votre demande',
  'order.detail.row.price': 'Rémunération',
  'order.detail.row.vehicle': 'Véhicule',
  'order.detail.row.vehicle.value': '{vehicle} minimum',
  'order.detail.row.proof': 'Preuve',
  'order.detail.pod.none_requested': 'Aucune preuve demandée',
  'order.detail.row.cod': 'À encaisser',
  'order.detail.cod.merchant_pays': ' (livraison à votre charge)',
  'order.detail.cod.client_pays': ' (livraison payée par le client)',
  'order.detail.row.dispatch': 'Diffusion',
  'order.detail.dispatch.favourites': 'Confiée à un favori',
  'order.detail.dispatch.network': 'Tout le réseau',
  'order.detail.row.instructions': 'Instructions',
  'order.detail.favourite.add': 'Ajouter {name} à mes transporteurs',
  'order.detail.favourite.hint':
      'Vos prochaines livraisons lui seront proposées en premier.',

  // ── Fiche de livraison : les échecs ─────────────────────────────────────
  'order.detail.failure.many': '{count} tentatives de livraison ont échoué',
  'order.detail.failure.one': 'La livraison n’a pas pu être effectuée',
  'order.detail.failure.attempt': 'Tentative {n}',
  'order.detail.failure.contact':
      'Contactez Echango pour convenir d’une nouvelle tentative.',

  // ── Motifs d'échec — PARTAGÉS entre le transporteur et le commerçant ────
  //
  // ⚠️ Ils existaient en **deux copies**, et trois libellés sur six avaient
  // divergé : le conducteur déclarait « Client a refusé le colis » et le
  // commerçant lisait « Colis refusé par le client » pour le même code. Un
  // seul endroit désormais, lu par les deux écrans via
  // `deliveryFailureLabel()`.
  'order.failure.client_absent': 'Client absent',
  'order.failure.adresse_introuvable': 'Adresse introuvable',
  'order.failure.colis_refuse': 'Colis refusé par le client',
  'order.failure.colis_endommage': 'Colis endommagé ou manquant',
  'order.failure.acces_impossible':
      'Accès impossible (site fermé, zone inaccessible)',
  'order.failure.autre': 'Autre motif',

  // ── Fiche de course (transporteur) ──────────────────────────────────────
  //
  // Vocabulaire distinct de celui du commerçant, et délibérément : le
  // transporteur prend une « course », le commerçant suit une « livraison ».
  'driver.order.title': 'Détail de la commande',
  'driver.order.not_found': 'Commande introuvable',
  'driver.order.number': 'Commande {id}',
  'driver.order.created': 'Créée le :',
  'driver.order.updated': 'Mise à jour :',
  'driver.order.cod.label': 'À encaisser : {amount}',
  'driver.order.cod.hint':
      'Somme due par le destinataire au commerçant. Vous la conservez et la '
          'lui remettez au prochain enlèvement.',
  'driver.order.redacted.title': 'Course non réclamée',
  'driver.order.redacted.body':
      'Le nom et le téléphone du destinataire apparaissent dès que vous '
          'acceptez. Tout le reste est affiché.',
  'driver.order.accept': 'Accepter cette course',
  'driver.order.accept.done': 'Course acceptée',
  'driver.order.activity.pod': '{label} (preuve requise)',
  'driver.order.activity.done': 'Étape appliquée : {label}',
  'driver.order.activity.failed': 'Échec de la mise à jour',
  'driver.order.decline': 'Refuser cette course',
  'driver.order.decline.body':
      'Elle ne vous sera plus proposée. Les autres transporteurs la voient '
          'toujours.',
  'driver.order.decline.done': 'Course écartée. Elle ne vous sera plus proposée.',
  'driver.order.decline.failed': 'Refus impossible',
  'driver.order.release': 'Rendre cette course',
  'driver.order.release.body':
      'Elle sera proposée aux autres transporteurs du réseau, et le commerçant '
          'en sera informé.',
  'driver.order.release.confirm': 'Rendre la course',
  'driver.order.release.done':
      'Course rendue au réseau. Le commerçant en a été informé.',
  'driver.order.note': 'Précision (facultatif)',
  'driver.order.report_failure': 'Signaler un échec de livraison',
  'driver.order.proof.hint':
      'Cette étape exige une photo : colis remis, signature, ou dépôt convenu.',
  'driver.order.proof.submit': 'Envoyer la preuve et valider l’étape',
  'driver.order.proof.failed': 'Envoi de la preuve impossible',
  'driver.order.place.no_address': 'Adresse non renseignée',
  'driver.order.place.address_in_notes': 'Adresse dans les précisions',
  'driver.order.place.contact': 'Contact : {name}',
  'driver.order.route': 'Itinéraire',
  'driver.order.nav.none':
      'Aucune application de navigation trouvée sur cet appareil.',
  'driver.order.call.failed': 'Impossible de lancer l’appel.',
  'driver.order.failures.many': '{count} échecs de livraison signalés',
  'driver.order.failures.one': 'Échec de livraison signalé',
  'driver.order.failures.attempt': 'Tentative {n} — {date}',
  'driver.order.failures.note':
      'La commande conserve son statut : le signalement est transmis à '
          'l’opérateur, qui décide de la suite.',
  'driver.order.failures.reason': 'Motif :',
  'driver.order.failures.notes': 'Notes :',
  'driver.order.cash.expected': 'Montant attendu : {amount}',
  'driver.order.cash.collected': 'Montant réellement perçu',
  'driver.order.cash.why': 'Pourquoi l’écart ?',
  'driver.order.cash.hint':
      'Cette somme sera ajoutée à ce que vous devez remettre au commerçant. '
          'Vous la retrouverez dans « Ma caisse ».',
  'driver.order.cash.submit': 'Valider et clôturer la livraison',

  // ── Motifs de refus — liste fermée du BFF, comme les motifs d'échec ─────
  'driver.reason.prix_insuffisant': 'Le prix ne couvre pas le trajet',
  'driver.reason.trop_loin': 'Trop loin de ma position',
  'driver.reason.vehicule_inadapte': 'Mon véhicule n’est pas adapté',
  'driver.reason.creneau_impossible': 'Je ne suis pas libre à cet horaire',
  'driver.reason.colis_inadapte': 'Le colis ne me convient pas',
  'driver.reason.indisponible': 'Je ne suis pas disponible',
  'driver.reason.autre': 'Autre raison',

  // ── Liste des livraisons (commerçant) ───────────────────────────────────
  'order.list.title': 'Mes livraisons',
  'order.list.notifications': 'Notifications',
  'order.list.cash': 'Encaissements',
  'order.list.addresses': 'Carnet d’adresses',
  'order.list.favourites': 'Mes transporteurs',
  'order.list.logout': 'Déconnexion',
  'order.list.search': 'Rechercher un destinataire, une adresse…',
  'order.list.tab.active': 'En cours',
  'order.list.tab.done': 'Terminées',
  'order.list.empty.active': 'Aucune livraison en cours',
  'order.list.empty.active.hint':
      'Appuyez sur « Nouvelle livraison » pour demander un transporteur.',
  'order.list.empty.done': 'Aucune livraison terminée',
  'order.list.empty.done.hint':
      'Vos livraisons achevées ou annulées se rangeront ici, avec leur preuve '
          'de remise.',
  'order.list.more': 'Charger les livraisons précédentes',
  // Repli quand le destinataire n'a pas de nom : distinct de la section
  // « Livraison » du formulaire, qui ne changerait pas avec lui.
  'order.list.fallback': 'Livraison',
  'order.list.driver': 'Transporteur : {name}',
  'order.list.status.unavailable': 'État indisponible',

  // ── Notifications ───────────────────────────────────────────────────────
  'order.notifications.title': 'Notifications',
  'order.notifications.mark_all': 'Tout marquer lu',
  'order.notifications.empty': 'Aucune notification',
  'order.notifications.empty.hint':
      'Vous serez prévenu ici quand un transporteur prend une de vos '
          'livraisons, et quand elle arrive à destination.',

  // ── Carnet d'adresses ───────────────────────────────────────────────────
  'order.book.title': 'Carnet d’adresses',
  'order.book.saved': 'Adresse enregistrée',
  'order.book.updated': 'Adresse modifiée',
  'order.book.deleted': 'Adresse supprimée',
  'order.book.delete': 'Supprimer',
  'order.book.delete.title': 'Supprimer « {name} » ?',
  'order.book.delete.body':
      'Elle disparaîtra du carnet. Vos livraisons passées ne sont pas '
          'affectées.',
  'order.book.delete.failed': 'Suppression impossible',
  'order.book.unavailable': 'Carnet d’adresses indisponible',
  'order.book.unavailable.hint':
      'Vos adresses n’ont pas pu être lues. Vérifiez votre connexion, puis '
          'réessayez.',
  'order.book.empty': 'Aucune adresse enregistrée',
  'order.book.empty.hint':
      'Enregistrez vos points de retrait et destinataires fréquents pour '
          'remplir une demande en un tap.',
  'order.book.default_badge': '· Principale',
  'order.book.no_position': 'Position manquante — à compléter',
  'order.book.position.title': 'Position de l’adresse',
  'order.book.replace.title': 'Remplacer l’adresse ?',
  'order.book.replace.body':
      'Préremplir le champ Adresse avec « {label} », la position que vous venez '
          'de sélectionner sur la carte ?',
  'order.book.replace.keep': 'Garder mon texte',
  'order.book.replace.confirm': 'Remplacer',
  'order.book.name.required': 'Le nom est obligatoire',
  'order.book.phone.required': 'Le téléphone est obligatoire',
  'order.book.save.failed': 'Enregistrement impossible',
  'order.book.form.edit': 'Modifier l’adresse',
  'order.book.form.new': 'Nouvelle adresse',
  'order.book.field.name': 'Nom *',
  'order.book.field.contact': 'Contact',
  'order.book.position.edit': 'Modifier la position',
  'order.book.position.unset':
      'Position non définie (facultatif) — à compléter avant de commander avec '
          'cette adresse',
  'order.book.position.set': 'Position définie',
  'order.book.default': 'Adresse principale',
  'order.book.default.hint':
      'Préremplit le retrait à chaque nouvelle livraison. Une seule adresse '
          'principale à la fois.',
  'order.book.save': 'Enregistrer',

  // ── Transporteurs favoris ───────────────────────────────────────────────
  'order.fav.title': 'Mes transporteurs',
  // ⚠️ **Plus de `{error}`.** Ces deux clés interpolaient l'exception brute —
  // les seuls sites du dépôt à le faire —, ce qui affichait soit le message
  // serveur en français à un utilisateur arabophone (règle 4), soit le code nu
  // `merchant.favourite_not_found`, soit le texte technique anglais d'un
  // `SocketException: Failed host lookup…`. Le message traduit vient désormais
  // de `messageForError()`, comme partout ailleurs.
  'order.fav.search.failed': 'Recherche impossible.',
  'order.fav.add.failed': 'Ajout impossible',
  // ── Journal d'évènements ────────────────────────────────────────────────
  //
  // ⚠️ Traduits **depuis le `type`**, jamais depuis le texte serveur. Le
  // réconciliateur écrit `title` et `body` en français dans son propre code :
  // les afficher tels quels faisait lire à un commerçant arabophone son unique
  // canal d'évènements entièrement en français, sous un titre arabe (règle 4,
  // revue du 01/08/2026 D1). Ils restent comme repli d'un type inconnu — c'est
  // le seul cas où un texte serveur a le droit d'atteindre l'écran.
  'order.notif.assigned.title': 'Livraison prise en charge',
  'order.notif.assigned.body': '{driver} a pris votre livraison {tracking}',
  // Sans nom de transporteur : le serveur n'a pas toujours la relation chargée,
  // et « a pris votre livraison » sans sujet ne se dit pas.
  'order.notif.assigned.body.anon': 'Un transporteur a pris votre livraison',
  'order.notif.released.title': 'Transporteur désisté',
  'order.notif.released.body':
      'Votre livraison a été proposée à nouveau aux transporteurs du réseau.',
  'order.notif.completed.title': 'Livraison effectuée',
  'order.notif.completed.body': 'Votre livraison est arrivée à destination.',
  'order.notif.canceled.title': 'Livraison annulée',
  'order.notif.canceled.body': 'Votre demande de livraison a été annulée.',
  'order.notif.failed.title': 'Échec de livraison',
  'order.notif.failed.body': 'Le transporteur n’a pas pu livrer votre commande. '
      'Ouvrez-la pour en voir le motif.',
  // Repli d'un type de notification que cette version ne connaît pas encore :
  // générique traduit, jamais le texte serveur (décision du 04/08/2026).
  'order.notif.unknown.title': 'Mise à jour de votre livraison',
  'order.notif.unknown.body': 'Ouvrez-la pour en voir le détail.',
  'order.fav.load.failed': 'Chargement impossible.',
  'order.fav.unavailable': 'Impossible de charger vos favoris.',
  'order.fav.unavailable.hint':
      'Vos favoris sont toujours enregistrés. Réessayez dans un instant.',
  'order.notif.unavailable': 'Impossible de relever votre journal.',
  'order.notif.unavailable.hint':
      'Des évènements ont peut-être eu lieu. Réessayez dans un instant.',
  'order.fav.add.section': 'Ajouter un transporteur',
  'order.fav.search': 'Nom ou téléphone du transporteur',
  'order.fav.search.hint':
      'Cherchez par le nom ou le téléphone communiqué par Echango. {min} '
          'caractères minimum.',
  'order.fav.search.too_many':
      'Trop de correspondances. Précisez le nom ou saisissez le numéro de '
          'téléphone.',
  'order.fav.search.none':
      'Aucun transporteur ne correspond. Vérifiez le nom, ou demandez-lui le '
          'numéro qu’il a donné à Echango.',
  'order.fav.no_account':
      'N’a pas encore installé l’application — aucune course ne lui sera '
          'proposée pour l’instant.',
  'order.fav.add': 'Ajouter aux favoris',
  'order.fav.section': 'Favoris',
  'order.fav.empty':
      'Aucun favori. Vos livraisons sont proposées à l’ensemble du réseau.',
  'order.fav.remove': 'Retirer des favoris',
  'order.fav.known': 'Déjà intervenus pour vous',
  'order.fav.known.empty':
      'Aucun autre transporteur pour l’instant. La liste se remplit au fil de '
          'vos livraisons.',

  // ── Sélecteur de point sur la carte ─────────────────────────────────────
  'order.map.search': 'Rechercher une adresse…',
  'order.map.searching': 'Recherche de l’adresse…',
  'order.map.no_address':
      'Point sans adresse connue — la position est tout de même utilisable',
  'order.map.confirm': 'Valider ce point',

  // ── Signalement d'échec (transporteur) ──────────────────────────────────
  'driver.failure.title': 'Signaler un échec de livraison',
  'driver.failure.intro': 'Indiquez pourquoi la livraison n’a pas pu se faire.',
  'driver.failure.reason': 'Motif',
  'driver.failure.notes': 'Notes complémentaires (facultatif)',
  'driver.failure.notes.hint': 'Précisions éventuelles…',
  'driver.failure.photo': 'Photo (facultative)',
  'driver.failure.photo.hint':
      'Utile quand l’échec se constate : porte close, adresse introuvable, '
          'colis refusé.',
  'driver.failure.submit': 'Signaler l’échec',
  'driver.failure.done': 'Échec de livraison signalé',
  'driver.failure.done.no_photo':
      'Signalement enregistré, mais la photo n’a pas pu être jointe.',
  'driver.failure.failed': 'Signalement impossible',

  // ── Fiche de course : compléments ───────────────────────────────────────
  'driver.order.decline.confirm': 'Refuser',
  'driver.order.cash.title': 'Encaissement',
};

const Map<String, String> _ar = {
  // ── Titres et sections ──────────────────────────────────────────────────
  'order.form.title.new': 'توصيل جديد',
  'order.form.title.duplicate': 'إعادة توصيل سابق',
  'order.section.pickup': 'الاستلام',
  'order.section.dropoff': 'التسليم',
  'order.section.parcel': 'الطرد',
  'order.form.section.options': 'خيارات',

  // ── Champs ──────────────────────────────────────────────────────────────
  'order.form.pickup.name': 'مكان الاستلام *',
  'order.form.pickup.contact': 'جهة الاتصال في المكان',
  'order.form.dropoff.name': 'المرسل إليه *',
  'order.form.dropoff.contact': 'جهة اتصال أخرى (إن وجدت)',
  'order.form.address': 'العنوان',
  'order.form.phone': 'الهاتف *',

  // ── Colis ───────────────────────────────────────────────────────────────
  'order.form.item.description': 'المحتوى (مثال: كعك، أدوية)',
  'order.form.item.quantity': 'عدد الطرود',
  'order.form.item.weight': 'الوزن التقريبي (كغ)',
  'order.form.item.fragile': 'محتوى قابل للكسر',
  'order.form.item.fragile.hint': 'يُعلَم الناقل قبل قبوله المهمة.',

  // ── Position ────────────────────────────────────────────────────────────
  'order.form.location.book': 'الدفتر',
  'order.form.location.pick': 'تحديد على الخريطة',
  'order.form.location.edit': 'تعديل النقطة',
  'order.form.location.unset': 'الموقع غير محدد',
  'order.form.location.set': 'الموقع محدد ({lat}، {lng})',
  'order.form.map.pickup': 'نقطة الاستلام',
  'order.form.map.dropoff': 'نقطة التسليم',

  // ── Véhicule ────────────────────────────────────────────────────────────
  'order.form.vehicle.label': 'المركبة المطلوبة',
  'order.form.vehicle.any': 'لا يهم',
  'order.form.vehicle.moto': 'دراجة نارية على الأقل',
  'order.form.vehicle.voiture': 'سيارة على الأقل',
  'order.form.vehicle.utilitaire': 'شاحنة صغيرة إلزامية',

  'order.vehicle.any': 'لا يهم',
  'order.vehicle.moto': 'دراجة نارية',
  'order.vehicle.voiture': 'سيارة',
  'order.vehicle.utilitaire': 'شاحنة صغيرة',

  // ── Ligne de colis ──────────────────────────────────────────────────────
  'order.item.weight': '{weight} كغ',
  'order.item.fragile': 'قابل للكسر',

  // ── Favoris : le repli quand la partie n'a pas de nom ────────────────────
  'order.party.driver.unnamed': 'ناقل {id}',
  'order.party.fleet.unnamed': 'شركة {id}',

  // ── Tarification ────────────────────────────────────────────────────────
  'order.form.price.label': 'الأجر المقترح (دج)',
  'order.form.price.hint':
      'هذا المبلغ يظهر للناقلين: على أساسه يقررون قبول المهمة.',
  'order.form.price.hint.distance':
      'المسافة التقريبية: {distance}. هذا المبلغ يظهر للناقلين.',
  'order.form.quote.flat': 'تسعيرة Echango لهذه المهمة',
  'order.form.quote.distance': 'تسعيرة Echango — {distance}',

  // ── Paiement à la livraison ─────────────────────────────────────────────
  'order.form.cod.enable': 'الزبون يدفع عند التسليم',
  'order.form.cod.enable.hint':
      'الناقل يقبض المبلغ ويسلّمه لك عند مروره القادم. Echango لا تحتفظ بهذا '
          'المال أبدًا.',
  'order.form.cod.amount.total': 'المبلغ المطلوب تحصيله (دج)',
  'order.form.cod.amount.goods': 'ثمن البضاعة (دج)',
  'order.form.cod.included': 'رسوم التوصيل مشمولة',
  'order.form.cod.included.hint': 'الزبون يدفع البضاعة والتوصيل دفعة واحدة.',
  'order.form.cod.excluded.hint':
      'رسوم التوصيل تُطلب من الزبون زيادة على ثمن البضاعة.',
  'order.form.cod.total.included': 'سيدفع المرسل إليه {amount} دج.',
  'order.form.cod.total.missing_fee':
      'حدّد أجر الناقل: سيُطلب من المرسل إليه زيادة على ثمن البضاعة.',
  'order.form.cod.total.excluded':
      'سيدفع المرسل إليه {total} دج ({goods} ثمن البضاعة + {fee} رسوم '
          'التوصيل).',
  'order.form.cod.settlement':
      'يقتطع الناقل أجره من المبلغ المحصَّل ولا يسلّمك سوى الفرق، عند مروره '
          'القادم.',

  // ── Enlèvement ──────────────────────────────────────────────────────────
  'order.schedule.title': 'الاستلام',
  'order.schedule.asap': 'في أقرب وقت',
  'order.form.schedule.clear': 'العودة إلى «في أقرب وقت»',

  // ── Preuve de livraison ─────────────────────────────────────────────────
  'order.pod.label': 'إثبات التسليم',
  'order.pod.photo': 'صورة عند التسليم',
  'order.form.pod.none': 'بدون إثبات',

  // ── Favoris ─────────────────────────────────────────────────────────────
  'order.form.favourites.title': 'اقتراحها أولًا على ناقليّ المعتادين',
  'order.form.favourites.hint':
      '{count} مفضّل. إذا لم يتوفر أحد منهم، تُعرض المهمة على كامل الشبكة.',
  'order.form.dispatch.label': 'إلى من تُسند المهمة',
  'order.form.dispatch.large': 'كامل الشبكة (بثّ واسع)',
  'order.form.dispatch.hint':
      'المفضّل المُسمّى يتلقّى المهمة وحده — تنتظره حتى وهو غير متصل. '
          'يمكنك دائمًا التحويل إلى البثّ الواسع.',

  // ── Instructions, brouillon, envoi ──────────────────────────────────────
  'order.form.instructions': 'تعليمات للناقل',
  'order.form.draft.notice':
      'هذا التوصيل مسجَّل كمسودة: لا يُطلب أي ناقل ما دمت لم تنشره من بطاقته.',
  'order.form.submit': 'حفظ كمسودة',

  // ── Carnet d'adresses (feuille) ─────────────────────────────────────────
  'order.form.book.search': 'البحث في الدفتر…',
  'order.form.book.empty': 'لا يوجد عنوان مطابق',

  // ── Messages ────────────────────────────────────────────────────────────
  'order.form.address.no_position':
      '«{name}» ليس له موقع مسجَّل: حدّده على الخريطة للمتابعة.',
  'order.form.missing': 'ينقص {fields}',
  'order.form.missing.separator': '، ',
  'order.form.missing.pickup_name': 'مكان الاستلام',
  'order.form.missing.pickup_phone': 'هاتف الاستلام',
  'order.form.missing.dropoff_name': 'اسم المرسل إليه',
  'order.form.missing.dropoff_phone': 'هاتف المرسل إليه',
  'order.form.missing.pickup_point': 'نقطة الاستلام على الخريطة',
  'order.form.missing.dropoff_point': 'نقطة التسليم على الخريطة',
  'order.form.invalid.price_max': 'لا يمكن أن يتجاوز السعر {max}',
  'order.form.invalid.cod_max': 'لا يمكن أن يتجاوز المبلغ المطلوب تحصيله {max}',
  'order.form.invalid.cod_min': 'مبلغ تحصيل قدره 0 يُدخَل بترك الحقل فارغًا',
  'order.form.saved':
      'حُفظت المسودة. راجعها ثم انشرها للعثور على ناقل.',
  'order.form.failed': 'تعذّر الإنشاء',

  // ── Fiche de livraison (commerçant) : actions ───────────────────────────
  'order.detail.title': 'متابعة التوصيل',
  'order.detail.not_found': 'التوصيل غير موجود',
  'order.detail.tracking': 'رقم التتبع: {number}',
  'order.detail.created': 'أُنشئ في {date}',
  'order.detail.publish': 'نشر',
  'order.detail.publish.done': 'نُشر التوصيل: Echango تبحث عن ناقل.',
  'order.detail.publish.failed': 'تعذّر النشر',
  'order.detail.redirect': 'إعادة توجيه المهمة',
  'order.detail.redirect.done': 'أُعيد توجيه المهمة.',
  'order.detail.redirect.failed': 'تعذّرت إعادة التوجيه',
  'order.detail.duplicate': 'إعادة هذا التوصيل',
  'order.detail.duplicate.failed': 'تعذّرت الإعادة — تُفتح الاستمارة فارغة.',
  'order.detail.cancel.title': 'إلغاء هذا التوصيل؟',
  'order.detail.cancel.body': 'سيُسحب الطلب. هذا الإجراء نهائي.',
  'order.detail.cancel.back': 'رجوع',
  'order.detail.cancel.confirm': 'إلغاء التوصيل',
  'order.detail.cancel.done': 'أُلغي التوصيل',
  'order.detail.cancel.failed': 'تعذّر الإلغاء',

  // ── Fiche de livraison : où ça en est ───────────────────────────────────
  'order.detail.state.draft':
      'مسودة: لا يُطلب أي ناقل ما دمت لم تنشر هذا التوصيل.',
  'order.detail.state.waiting': 'في انتظار الإسناد. Echango تبحث عن ناقل متاح.',
  'order.detail.state.assigned': 'أُسند ناقل. تبدأ المهمة عند الاستلام.',
  'order.detail.state.completed': 'تم التوصيل.',
  'order.detail.state.cancelled': 'أُلغي التوصيل.',

  // ── Fiche de livraison : le transporteur ────────────────────────────────
  'order.detail.driver.assigned': 'تكفّل به {name}',
  'order.detail.driver.call': 'الاتصال بالناقل',
  'order.detail.driver.call.short': 'اتصال',
  'order.detail.driver.position': 'عرض موقع الناقل',
  'order.detail.driver.position.none': 'موقع الناقل غير متاح حاليًا.',
  'order.detail.driver.position.unknown': 'آخر موقع معروف، التاريخ مجهول',
  'order.detail.driver.position.seen': 'سُجّل الموقع {when}',
  'order.detail.refresh': 'تحديث',

  // ── Fiche de livraison : l'argent ───────────────────────────────────────
  'order.detail.cash.title': 'الدفع عند التسليم',
  'order.detail.cash.requested': 'المبلغ المطلوب: {amount}',
  'order.detail.cash.pending': 'لم يُحصَّل بعد.',
  'order.detail.cash.collected': 'المحصَّل: {amount}',
  'order.detail.cash.held':
      'هذا المبلغ في حوزة الناقل إلى حين تسليمه. تابعه في «التحصيلات».',
  'order.detail.cash.will_return': 'سيعود إليك',
  'order.detail.cash.returns': 'يعود إليك',
  'order.detail.cash.net': '{tense}: {amount}',
  'order.detail.cash.owed': 'ستكون مدينًا للناقل بـ: {amount}',
  'order.detail.cash.settlement':
      'يقتطع الناقل أجره ({fee}) مما يحصّله ويسلّمك الفرق.',

  // ── Fiche de livraison : ce qui a été demandé ───────────────────────────
  'order.detail.request': 'طلبك',
  'order.detail.row.price': 'الأجر',
  'order.detail.row.vehicle': 'المركبة',
  'order.detail.row.vehicle.value': '{vehicle} على الأقل',
  'order.detail.row.proof': 'الإثبات',
  'order.detail.pod.none_requested': 'لا إثبات مطلوب',
  'order.detail.row.cod': 'للتحصيل',
  'order.detail.cod.merchant_pays': ' (التوصيل على حسابك)',
  'order.detail.cod.client_pays': ' (التوصيل يدفعه الزبون)',
  'order.detail.row.dispatch': 'النشر',
  'order.detail.dispatch.favourites': 'مُسندة إلى مفضّل',
  'order.detail.dispatch.network': 'كامل الشبكة',
  'order.detail.row.instructions': 'التعليمات',
  'order.detail.favourite.add': 'إضافة {name} إلى ناقليّ',
  'order.detail.favourite.hint': 'ستُعرض عليه توصيلاتك القادمة أولًا.',

  // ── Fiche de livraison : les échecs ─────────────────────────────────────
  'order.detail.failure.many': 'فشلت {count} محاولات تسليم',
  'order.detail.failure.one': 'تعذّر إتمام التسليم',
  'order.detail.failure.attempt': 'المحاولة {n}',
  'order.detail.failure.contact': 'اتصل بـ Echango للاتفاق على محاولة جديدة.',

  // ── Motifs d'échec — PARTAGÉS ───────────────────────────────────────────
  'order.failure.client_absent': 'الزبون غائب',
  'order.failure.adresse_introuvable': 'العنوان غير موجود',
  'order.failure.colis_refuse': 'رفض الزبون الطرد',
  'order.failure.colis_endommage': 'طرد متضرر أو ناقص',
  'order.failure.acces_impossible': 'تعذّر الوصول (موقع مغلق، منطقة غير قابلة للولوج)',
  'order.failure.autre': 'سبب آخر',

  // ── Fiche de course (transporteur) ──────────────────────────────────────
  'driver.order.title': 'تفاصيل الطلب',
  'driver.order.not_found': 'الطلب غير موجود',
  'driver.order.number': 'الطلب {id}',
  'driver.order.created': 'أُنشئ في:',
  'driver.order.updated': 'آخر تحديث:',
  'driver.order.cod.label': 'للتحصيل: {amount}',
  'driver.order.cod.hint':
      'مبلغ يدين به المرسل إليه للتاجر. تحتفظ به وتسلّمه له عند الاستلام '
          'القادم.',
  'driver.order.redacted.title': 'مهمة غير محجوزة',
  'driver.order.redacted.body':
      'يظهر اسم المرسل إليه وهاتفه بمجرد قبولك. وكل ما عدا ذلك معروض.',
  'driver.order.accept': 'قبول هذه المهمة',
  'driver.order.accept.done': 'قُبلت المهمة',
  'driver.order.activity.pod': '{label} (إثبات مطلوب)',
  'driver.order.activity.done': 'طُبّقت المرحلة: {label}',
  'driver.order.activity.failed': 'فشل التحديث',
  'driver.order.decline': 'رفض هذه المهمة',
  'driver.order.decline.body':
      'لن تُعرض عليك بعد الآن. ويبقى الناقلون الآخرون يرونها.',
  'driver.order.decline.done': 'استُبعدت المهمة. لن تُعرض عليك بعد الآن.',
  'driver.order.decline.failed': 'تعذّر الرفض',
  'driver.order.release': 'إرجاع هذه المهمة',
  'driver.order.release.body':
      'ستُعرض على ناقلي الشبكة الآخرين، وسيُعلَم التاجر بذلك.',
  'driver.order.release.confirm': 'إرجاع المهمة',
  'driver.order.release.done': 'أُرجعت المهمة إلى الشبكة. وأُعلم التاجر بذلك.',
  'driver.order.note': 'توضيح (اختياري)',
  'driver.order.report_failure': 'الإبلاغ عن فشل التسليم',
  'driver.order.proof.hint':
      'تتطلب هذه المرحلة صورة: الطرد مسلَّم، توقيع، أو إيداع متفق عليه.',
  'driver.order.proof.submit': 'إرسال الإثبات وإتمام المرحلة',
  'driver.order.proof.failed': 'تعذّر إرسال الإثبات',
  'driver.order.place.no_address': 'العنوان غير مذكور',
  'driver.order.place.address_in_notes': 'العنوان في التوضيحات',
  'driver.order.place.contact': 'جهة الاتصال: {name}',
  'driver.order.route': 'المسار',
  'driver.order.nav.none': 'لا يوجد تطبيق ملاحة على هذا الجهاز.',
  'driver.order.call.failed': 'تعذّر إجراء المكالمة.',
  'driver.order.failures.many': '{count} حالات فشل تسليم مُبلَّغ عنها',
  'driver.order.failures.one': 'أُبلغ عن فشل التسليم',
  'driver.order.failures.attempt': 'المحاولة {n} — {date}',
  'driver.order.failures.note':
      'يحتفظ الطلب بحالته: يُرسَل البلاغ إلى المشغّل، وهو من يقرر ما يليه.',
  'driver.order.failures.reason': 'السبب:',
  'driver.order.failures.notes': 'ملاحظات:',
  'driver.order.cash.expected': 'المبلغ المتوقع: {amount}',
  'driver.order.cash.collected': 'المبلغ المحصَّل فعليًا',
  'driver.order.cash.why': 'ما سبب الفارق؟',
  'driver.order.cash.hint':
      'يُضاف هذا المبلغ إلى ما عليك تسليمه للتاجر. ستجده في «صندوقي».',
  'driver.order.cash.submit': 'التأكيد وإغلاق التوصيل',

  // ── Motifs de refus ─────────────────────────────────────────────────────
  'driver.reason.prix_insuffisant': 'السعر لا يغطي المسافة',
  'driver.reason.trop_loin': 'بعيد جدًا عن موقعي',
  'driver.reason.vehicule_inadapte': 'مركبتي غير مناسبة',
  'driver.reason.creneau_impossible': 'لست متفرغًا في هذا الموعد',
  'driver.reason.colis_inadapte': 'الطرد لا يناسبني',
  'driver.reason.indisponible': 'لست متاحًا',
  'driver.reason.autre': 'سبب آخر',

  // ── Liste des livraisons (commerçant) ───────────────────────────────────
  'order.list.title': 'توصيلاتي',
  'order.list.notifications': 'الإشعارات',
  'order.list.cash': 'التحصيلات',
  'order.list.addresses': 'دفتر العناوين',
  'order.list.favourites': 'ناقليّ',
  'order.list.logout': 'تسجيل الخروج',
  'order.list.search': 'ابحث عن مرسل إليه أو عنوان…',
  'order.list.tab.active': 'الجارية',
  'order.list.tab.done': 'المنتهية',
  'order.list.empty.active': 'لا يوجد توصيل جارٍ',
  'order.list.empty.active.hint':
      'اضغط «توصيل جديد» لطلب ناقل.',
  'order.list.empty.done': 'لا يوجد توصيل منتهٍ',
  'order.list.empty.done.hint':
      'ستُرتَّب هنا توصيلاتك المنتهية أو الملغاة، مع إثبات التسليم.',
  'order.list.more': 'تحميل التوصيلات السابقة',
  'order.list.fallback': 'توصيل',
  'order.list.driver': 'الناقل: {name}',
  'order.list.status.unavailable': 'الحالة غير متاحة',

  // ── Notifications ───────────────────────────────────────────────────────
  'order.notifications.title': 'الإشعارات',
  'order.notifications.mark_all': 'تعليم الكل كمقروء',
  'order.notifications.empty': 'لا توجد إشعارات',
  'order.notifications.empty.hint':
      'ستُعلَم هنا عندما يأخذ ناقل أحد توصيلاتك، وعندما يصل إلى وجهته.',

  // ── Carnet d'adresses ───────────────────────────────────────────────────
  'order.book.title': 'دفتر العناوين',
  'order.book.saved': 'حُفظ العنوان',
  'order.book.updated': 'عُدّل العنوان',
  'order.book.deleted': 'حُذف العنوان',
  'order.book.delete': 'حذف',
  'order.book.delete.title': 'حذف «{name}»؟',
  'order.book.delete.body':
      'سيختفي من الدفتر. ولن تتأثر توصيلاتك السابقة.',
  'order.book.delete.failed': 'تعذّر الحذف',
  'order.book.unavailable': 'دفتر العناوين غير متاح',
  'order.book.unavailable.hint':
      'تعذّرت قراءة عناوينك. تحقّق من اتصالك ثم أعد المحاولة.',
  'order.book.empty': 'لا يوجد عنوان مسجَّل',
  'order.book.empty.hint':
      'سجّل نقاط الاستلام والمرسل إليهم المتكررين لملء الطلب بضغطة واحدة.',
  'order.book.default_badge': '· رئيسي',
  'order.book.no_position': 'الموقع ناقص — يجب استكماله',
  'order.book.position.title': 'موقع العنوان',
  'order.book.replace.title': 'استبدال العنوان؟',
  'order.book.replace.body':
      'هل تريد ملء حقل العنوان بـ«{label}»، الموقع الذي حدّدته على الخريطة؟',
  'order.book.replace.keep': 'الإبقاء على نصي',
  'order.book.replace.confirm': 'استبدال',
  'order.book.name.required': 'الاسم إلزامي',
  'order.book.phone.required': 'الهاتف إلزامي',
  'order.book.save.failed': 'تعذّر الحفظ',
  'order.book.form.edit': 'تعديل العنوان',
  'order.book.form.new': 'عنوان جديد',
  'order.book.field.name': 'الاسم *',
  'order.book.field.contact': 'جهة الاتصال',
  'order.book.position.edit': 'تعديل الموقع',
  'order.book.position.unset':
      'الموقع غير محدد (اختياري) — يجب استكماله قبل الطلب بهذا العنوان',
  'order.book.position.set': 'الموقع محدد',
  'order.book.default': 'العنوان الرئيسي',
  'order.book.default.hint':
      'يملأ الاستلام مسبقًا في كل توصيل جديد. عنوان رئيسي واحد فقط.',
  'order.book.save': 'حفظ',

  // ── Transporteurs favoris ───────────────────────────────────────────────
  'order.fav.title': 'ناقليّ',
  'order.fav.search.failed': 'تعذّر البحث.',
  'order.fav.add.failed': 'تعذّرت الإضافة',
  'order.notif.assigned.title': 'تم استلام التوصيلة',
  'order.notif.assigned.body': 'أخذ {driver} توصيلتك {tracking}',
  'order.notif.assigned.body.anon': 'أخذ أحد الناقلين توصيلتك',
  'order.notif.released.title': 'انسحب الناقل',
  'order.notif.released.body': 'أُعيد عرض توصيلتك على ناقلي الشبكة.',
  'order.notif.completed.title': 'تمت التوصيلة',
  'order.notif.completed.body': 'وصلت توصيلتك إلى وجهتها.',
  'order.notif.canceled.title': 'أُلغيت التوصيلة',
  'order.notif.canceled.body': 'أُلغي طلب التوصيل الخاص بك.',
  'order.notif.failed.title': 'فشل التوصيل',
  'order.notif.failed.body': 'لم يتمكن الناقل من تسليم طلبك. افتحه لمعرفة السبب.',
  'order.notif.unknown.title': 'تحديث بخصوص توصيلتك',
  'order.notif.unknown.body': 'افتحها لعرض التفاصيل.',
  'order.fav.load.failed': 'تعذّر التحميل.',
  'order.fav.unavailable': 'تعذّر تحميل مفضّليك.',
  'order.fav.unavailable.hint': 'مفضّلوك ما زالوا مسجّلين. أعد المحاولة بعد قليل.',
  'order.notif.unavailable': 'تعذّر تحديث سجلّك.',
  'order.notif.unavailable.hint':
      'ربما وقعت أحداث. أعد المحاولة بعد قليل.',
  'order.fav.add.section': 'إضافة ناقل',
  'order.fav.search': 'اسم الناقل أو هاتفه',
  'order.fav.search.hint':
      'ابحث بالاسم أو بالهاتف الذي أعطته Echango. {min} أحرف على الأقل.',
  'order.fav.search.too_many':
      'نتائج كثيرة. حدّد الاسم أكثر أو أدخل رقم الهاتف.',
  'order.fav.search.none':
      'لا يوجد ناقل مطابق. تحقّق من الاسم، أو اطلب منه الرقم الذي أعطاه '
          'لـEchango.',
  'order.fav.no_account':
      'لم يثبّت التطبيق بعد — لن تُعرض عليه أي مهمة حاليًا.',
  'order.fav.add': 'إضافة إلى المفضلة',
  'order.fav.section': 'المفضّلون',
  'order.fav.empty': 'لا يوجد مفضّل. تُعرض توصيلاتك على كامل الشبكة.',
  'order.fav.remove': 'إزالة من المفضلة',
  'order.fav.known': 'سبق أن عملوا معك',
  'order.fav.known.empty':
      'لا يوجد ناقل آخر حاليًا. تمتلئ القائمة مع توالي توصيلاتك.',

  // ── Sélecteur de point sur la carte ─────────────────────────────────────
  'order.map.search': 'ابحث عن عنوان…',
  'order.map.searching': 'جارٍ البحث عن العنوان…',
  'order.map.no_address':
      'نقطة بدون عنوان معروف — الموقع صالح للاستعمال مع ذلك',
  'order.map.confirm': 'تأكيد هذه النقطة',

  // ── Signalement d'échec (transporteur) ──────────────────────────────────
  'driver.failure.title': 'الإبلاغ عن فشل التسليم',
  'driver.failure.intro': 'بيّن سبب تعذّر التسليم.',
  'driver.failure.reason': 'السبب',
  'driver.failure.notes': 'ملاحظات إضافية (اختياري)',
  'driver.failure.notes.hint': 'توضيحات عند الاقتضاء…',
  'driver.failure.photo': 'صورة (اختيارية)',
  'driver.failure.photo.hint':
      'مفيدة عندما يكون الفشل ظاهرًا: باب مغلق، عنوان غير موجود، طرد مرفوض.',
  'driver.failure.submit': 'الإبلاغ عن الفشل',
  'driver.failure.done': 'أُبلغ عن فشل التسليم',
  'driver.failure.done.no_photo':
      'سُجّل البلاغ، لكن تعذّر إرفاق الصورة.',
  'driver.failure.failed': 'تعذّر الإبلاغ',

  // ── Fiche de course : compléments ───────────────────────────────────────
  'driver.order.decline.confirm': 'رفض',
  'driver.order.cash.title': 'التحصيل',
};
