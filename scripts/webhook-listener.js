#!/usr/bin/env node
/**
 * Écouteur de webhooks, pour le contrôle V8 du plan de migration.
 *
 * ── Pourquoi un serveur à part, et non la route du BFF ───────────────────────
 *
 * Fleetbase exige une URL **publique** : impossible de lui donner
 * `localhost` ou `host.docker.internal`. Il faut donc un tunnel — et tunneler
 * le BFF exposerait sur Internet l'authentification, les données commerçants et
 * le registre de caisse, alors qu'on ne veut observer qu'une chose.
 *
 * Ce processus n'expose qu'un port qui ne sait rien faire : il lit, il affiche,
 * il répond 200. Il n'a aucune dépendance, n'écrit sur aucun disque, ne touche
 * à aucune base. C'est la surface la plus petite qui réponde à la question.
 *
 * ── Ce qu'on cherche, par ordre d'importance ────────────────────────────────
 *
 * 1. Le **nom et le format de l'en-tête de signature** — la seule chose que le
 *    Lot 5 ne peut pas deviner, et sans laquelle l'endpoint reste
 *    indéployable.
 * 2. Le **vocabulaire réel des évènements** — leurs noms exacts, pas ceux
 *    qu'on suppose.
 * 3. La **forme du corps** — la commande entière, ou seulement des
 *    identifiants ? Ça décide si un webhook suffit ou s'il faut relire
 *    derrière.
 *
 * ── Usage ───────────────────────────────────────────────────────────────────
 *
 *   node scripts/webhook-listener.js            # port 3002
 *   PORT=4000 node scripts/webhook-listener.js
 *
 * Puis, dans un second terminal, un tunnel vers ce port :
 *
 *   cloudflared tunnel --url http://localhost:3002     # sans compte
 *   ngrok http 3002                                    # compte requis
 *
 * L'URL publique affichée par le tunnel va dans le formulaire Fleetbase,
 * suffixée du chemin de ton choix — ce serveur répond sur tous.
 *
 * ⚠️ Le tunnel est ouvert à qui connaît l'URL. Ce serveur ne fait rien de
 * dangereux, mais coupe-le quand même une fois l'observation terminée : les
 * corps affichés contiennent les adresses et téléphones des destinataires.
 */
const http = require('http');

const PORT = Number(process.env.PORT) || 3002;
let count = 0;

/** En-têtes susceptibles de porter la signature ou le type d'évènement. */
const INTERESTING = /signature|fleetbase|webhook|event|hook|timestamp|^x-/i;

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));

  req.on('end', () => {
    count += 1;
    const raw = Buffer.concat(chunks).toString('utf8');

    console.log('\n' + '═'.repeat(78));
    console.log(`ÉVÈNEMENT #${count} — ${new Date().toISOString()}`);
    console.log(`${req.method} ${req.url}`);
    console.log('─'.repeat(78));

    // Les en-têtes d'abord : c'est là qu'est la réponse à la question 1.
    const headers = Object.entries(req.headers);
    const flagged = headers.filter(([k]) => INTERESTING.test(k));

    console.log('En-têtes remarquables :');
    if (flagged.length) {
      for (const [k, v] of flagged) console.log(`  ${k}: ${v}`);
    } else {
      console.log('  (aucun — pas de signature ? vérifier la liste complète)');
    }

    console.log('\nTous les en-têtes :');
    for (const [k, v] of headers) console.log(`  ${k}: ${v}`);

    console.log('\nCorps :');
    try {
      const body = JSON.parse(raw);
      // Le type et les clés de premier niveau AVANT le corps entier : sur un
      // objet de plusieurs centaines de lignes, l'essentiel se perd sinon.
      console.log(`  type annoncé : ${body?.event ?? body?.type ?? '(aucun champ event/type)'}`);
      console.log(`  clés         : ${Object.keys(body).join(', ')}`);
      console.log('\n' + JSON.stringify(body, null, 2));
    } catch {
      // Un corps non-JSON est une information en soi, pas une erreur.
      console.log(raw || '  (vide)');
    }

    console.log('═'.repeat(78));

    // Toujours 200 : un rejet ferait réessayer Fleetbase en boucle sans rien
    // nous apprendre de plus.
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ received: true }));
  });
});

server.listen(PORT, () => {
  console.log(`Écouteur de webhooks sur http://localhost:${PORT}`);
  console.log('Répond 200 sur tous les chemins et toutes les méthodes.');
  console.log('\nOuvrir un tunnel dans un autre terminal :');
  console.log(`  cloudflared tunnel --url http://localhost:${PORT}`);
  console.log('\nEn attente…');
});
