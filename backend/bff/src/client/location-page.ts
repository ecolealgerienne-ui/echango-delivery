import { LinkState } from './client.service';

/**
 * Page publique de partage de position — §1.8 de
 * `docs/specs_localisation_client_et_optimisation_parcours.md`.
 *
 * ⚠️ **Ne montre jamais** de donnée métier (nom du commerçant, contenu de la
 * commande) : c'est ce qui rend cette page sûre à partager sur n'importe quel
 * canal. L'état (en attente / expiré / déjà utilisé / introuvable) est
 * tranché côté serveur avant le rendu — le JS embarqué ne fait que la
 * géolocalisation et la soumission, jamais de logique d'état.
 *
 * ⚠️ **FR + AR affichés ensemble**, plutôt que sélectionnés par
 * `Accept-Language` : c'est un seul écran, sans registre i18n comme le reste
 * de l'application (le contrat `AppError`/`error_translator.dart` de la
 * règle 4 de CLAUDE.md ne s'étend pas à cette page autonome), et deviner la
 * langue d'un navigateur inconnu risquerait de rendre le consentement illisible
 * pour la moitié des destinataires. Un compromis délibéré, pas un oubli.
 */
export function renderLocationPage(state: LinkState, token: string): string {
  const body = {
    pending: pendingBody(token),
    expired: messageBody(
      '⏱️ Lien expiré / انتهت صلاحية الرابط',
      'Ce lien de localisation a expiré (validité : 10 minutes). Demandez-en un nouveau au commerçant.',
      'انتهت صلاحية رابط الموقع هذا (المدة: 10 دقائق). اطلب رابطًا جديدًا من التاجر.',
    ),
    used: messageBody(
      '✅ Lien déjà utilisé / تم استخدام الرابط',
      'Ce lien a déjà servi à partager une position. Demandez-en un nouveau si besoin.',
      'تم استخدام هذا الرابط بالفعل لمشاركة موقع. اطلب رابطًا جديدًا إذا لزم الأمر.',
    ),
    not_found: messageBody(
      '❓ Lien introuvable / الرابط غير موجود',
      "Ce lien n'existe pas ou n'est plus valide.",
      'هذا الرابط غير موجود أو لم يعد صالحًا.',
    ),
  }[state];

  return `<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Echango — Partage de position</title>
<style>
  :root { color-scheme: light; }
  body {
    margin: 0; padding: 24px; min-height: 100vh; box-sizing: border-box;
    display: flex; align-items: center; justify-content: center;
    background: #f4f5f7; color: #1a1a1a;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Arial, sans-serif;
  }
  .card {
    max-width: 420px; width: 100%; background: #fff; border-radius: 16px;
    padding: 28px 24px; box-shadow: 0 2px 12px rgba(0,0,0,0.08); text-align: center;
  }
  .brand { font-weight: 700; font-size: 20px; margin-bottom: 4px; color: #0a6b3d; }
  h1 { font-size: 17px; margin: 12px 0; }
  p { font-size: 14px; line-height: 1.5; color: #444; }
  .consent { font-size: 12px; color: #666; margin: 16px 0; }
  button {
    width: 100%; padding: 14px; border-radius: 10px; border: none;
    background: #0a6b3d; color: #fff; font-size: 15px; font-weight: 600;
    cursor: pointer; margin-top: 8px;
  }
  button:disabled { background: #9aa; cursor: default; }
  .status { font-size: 13px; margin-top: 14px; min-height: 18px; }
  .status.error { color: #b3261e; }
  .status.success { color: #0a6b3d; }
</style>
</head>
<body>
  <div class="card">
    <div class="brand">Echango</div>
    ${body}
  </div>
${state === 'pending' ? script(token) : ''}
</body>
</html>`;
}

function messageBody(title: string, fr: string, ar: string): string {
  return `<h1>${title}</h1><p>${fr}</p><p dir="rtl">${ar}</p>`;
}

function pendingBody(_token: string): string {
  return `
    <h1>📍 Partager ma position / مشاركة موقعي</h1>
    <p>Un commerçant a besoin de votre position exacte pour livrer votre commande.</p>
    <p dir="rtl">يحتاج التاجر إلى موقعك الدقيق لتوصيل طلبك.</p>
    <p class="consent">
      Votre position sera utilisée pour vos livraisons sur le réseau Echango.<br>
      <span dir="rtl">سيتم استخدام موقعك لتوصيل طلباتك عبر شبكة Echango.</span>
    </p>
    <button id="share-btn">Partager ma position / مشاركة الموقع</button>
    <div id="status" class="status"></div>
  `;
}

function script(token: string): string {
  // Chaîne littérale : pas d'interpolation de donnée utilisateur dans le JS,
  // seul `token` (déjà validé côté serveur avant le rendu de cet état) est
  // injecté, et il est passé à `fetch` en tant que valeur, jamais concaténé
  // dans du HTML/JS exécutable.
  return `<script>
(function () {
  var btn = document.getElementById('share-btn');
  var status = document.getElementById('status');
  var token = ${JSON.stringify(token)};

  function setStatus(text, cls) {
    status.textContent = text;
    status.className = 'status' + (cls ? ' ' + cls : '');
  }

  btn.addEventListener('click', function () {
    if (!('geolocation' in navigator)) {
      setStatus('Géolocalisation non disponible sur cet appareil. / تحديد الموقع غير متاح على هذا الجهاز.', 'error');
      return;
    }
    btn.disabled = true;
    setStatus('Localisation en cours… / جارٍ تحديد الموقع…');

    navigator.geolocation.getCurrentPosition(function (pos) {
      fetch(window.location.pathname, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ lat: pos.coords.latitude, lng: pos.coords.longitude }),
      })
        .then(function (res) { return res.json().then(function (data) { return { ok: res.ok, data: data }; }); })
        .then(function (result) {
          if (result.ok) {
            setStatus('Position partagée, merci ! / تم مشاركة الموقع، شكرًا لك!', 'success');
          } else {
            setStatus((result.data && result.data.message) || 'Échec de l\\'envoi.', 'error');
            btn.disabled = false;
          }
        })
        .catch(function () {
          setStatus('Erreur réseau. Réessayez. / خطأ في الشبكة. أعد المحاولة.', 'error');
          btn.disabled = false;
        });
    }, function () {
      setStatus('Localisation refusée. Autorisez-la pour continuer. / تم رفض تحديد الموقع. يرجى السماح به للمتابعة.', 'error');
      btn.disabled = false;
    });
  });
})();
</script>`;
}
