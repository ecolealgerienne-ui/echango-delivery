/**
 * Provisionne le **prestataire plateforme Echango** — l'étape 0 du chantier
 * facilitateur (`docs/specs_facilitateur.md` §2.2, §7.4, Lot 0).
 *
 * ── Pourquoi cet enregistrement doit exister avant tout le reste ────────────
 *
 * La décision du 31/07/2026 est qu'il y a **toujours un facilitateur**, Echango
 * étant celui des courses du pool. Sans cette ligne, une course du pool n'a
 * personne à désigner, et la règle « le facilitateur doit au commerçant » n'a
 * pas de sujet. C'est l'étape que `specs_flux_argent_quatre_acteurs.md` §7
 * appelait « poser le prestataire Echango ».
 *
 * ── Idempotent, et il doit l'être ───────────────────────────────────────────
 *
 * Ce script sera relancé — après une migration, sur un nouvel environnement,
 * par quelqu'un qui ne sait plus s'il l'a déjà passé. Il ne crée jamais un
 * second prestataire plateforme : `isPlatform` doit rester vrai pour
 * **exactement un** enregistrement, sans quoi la résolution du facilitateur
 * n'aurait plus de réponse unique.
 *
 * ── Ce qu'il NE fait pas ────────────────────────────────────────────────────
 *
 * Il ne crée pas de compte opérateur utilisable pour se connecter si les
 * identifiants ne sont pas fournis : mieux vaut un prestataire sans session
 * qu'un compte à mot de passe deviné. Le persona opérateur (lire le registre,
 * confirmer les remises reçues) est le Lot 1.
 *
 *   npm run prisma:seed
 *
 *   ECHANGO_PLATFORM_NAME      nom du Vendor (défaut : « Echango Delivery »)
 *   ECHANGO_PLATFORM_EMAIL     email du compte opérateur
 *   ECHANGO_PLATFORM_PASSWORD  mot de passe (≥ 12 caractères)
 */
import { PrismaClient } from '@prisma/client';
import axios from 'axios';
import * as bcrypt from 'bcrypt';
import { randomBytes } from 'crypto';

const prisma = new PrismaClient();

const NAME = process.env.ECHANGO_PLATFORM_NAME || 'Echango Delivery';
const EMAIL = process.env.ECHANGO_PLATFORM_EMAIL || '';
const PASSWORD = process.env.ECHANGO_PLATFORM_PASSWORD || '';
const MIN_PASSWORD_LENGTH = 12;

function fleetbase() {
  const baseURL = process.env.FLEETBASE_API_URL;
  const apiKey = process.env.FLEETBASE_API_KEY;

  if (!baseURL || !apiKey) {
    throw new Error(
      'FLEETBASE_API_URL et FLEETBASE_API_KEY sont requis : le prestataire plateforme est un ' +
        'Vendor Fleetbase, pas seulement une ligne locale.',
    );
  }

  return axios.create({
    baseURL,
    headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
    timeout: 30000,
  });
}

/**
 * Cherche le Vendor Echango par son nom, en paginant.
 *
 * Sans pagination, « introuvable » aurait fini par vouloir dire « au-delà de la
 * première page », et le script aurait créé un second Vendor Echango à chaque
 * exécution une fois le réseau assez grand. Même défaut que celui corrigé le
 * même jour sur `getVendorByUuid`.
 */
async function findVendorByName(api: ReturnType<typeof fleetbase>, name: string) {
  const pageSize = 200;
  let previousFirstUuid: string | null = null;

  for (let page = 1; page <= 25; page++) {
    const { data } = await api.get('/int/v1/vendors', { params: { page, limit: pageSize } });
    const vendors: any[] = data?.vendors ?? data?.data ?? [];

    const found = vendors.find((v) => v?.name === name);
    if (found) return found;
    if (vendors.length === 0) return null;

    // Même précaution que `findVendorAcrossPages` : ne rien supposer de `limit`
    // ni de `page`. Ici l'enjeu est plus direct encore — conclure « introuvable »
    // à tort crée un **second** Vendor Echango, ce que cette fonction existe
    // précisément pour empêcher.
    const firstUuid: string | null = vendors[0]?.uuid ?? null;
    if (page > 1 && firstUuid !== null && firstUuid === previousFirstUuid) {
      throw new Error(
        `/int/v1/vendors semble ignorer le paramètre « page » — refus de conclure que ` +
          `« ${name} » n'existe pas, et donc de le créer en double.`,
      );
    }
    previousFirstUuid = firstUuid;
  }

  throw new Error(
    `Recherche du Vendor « ${name} » tronquée après 25 pages — refus de créer un doublon.`,
  );
}

async function main() {
  const hasCredentials = EMAIL !== '' && PASSWORD.length >= MIN_PASSWORD_LENGTH;

  if (EMAIL !== '' && !hasCredentials) {
    throw new Error(
      `ECHANGO_PLATFORM_PASSWORD fait ${PASSWORD.length} caractères, minimum ` +
        `${MIN_PASSWORD_LENGTH}. Ce compte voit le registre de caisse de tout le réseau.`,
    );
  }

  const existing = await prisma.fleetAccount.findFirst({ where: { isPlatform: true } });

  if (existing) {
    // ── Un second passage AVEC identifiants doit pouvoir ouvrir le compte ───
    //
    // La première version sortait ici quoi qu'il arrive. Or le premier passage
    // se fait souvent sans identifiants — on ne les a pas encore choisis — et
    // le compte naît alors inconnectable. Sortir sans rien faire rendait le SQL
    // manuel obligatoire pour le seul compte capable d'inviter un conducteur du
    // pool. Le script doit finir ce qu'il a commencé.
    if (hasCredentials) {
      const opened = await prisma.fleetAccount.update({
        where: { id: existing.id },
        data: { email: EMAIL, password: await bcrypt.hash(PASSWORD, 10), active: true },
      });
      console.log(`✅ Compte opérateur ouvert sur le prestataire existant : ${opened.email}`);
      return;
    }

    console.log(
      `✅ Prestataire plateforme déjà en place : ${existing.businessName} ` +
        `(${existing.id}, vendor ${existing.fleetbaseVendorUuid})` +
        (existing.active
          ? ''
          : '\n   ⚠️ Compte non connectable. Relancez avec ECHANGO_PLATFORM_EMAIL et ' +
            'ECHANGO_PLATFORM_PASSWORD pour l’ouvrir.'),
    );
    return;
  }

  const api = fleetbase();

  let vendor = await findVendorByName(api, NAME);
  let vendorWasCreated = false;

  if (vendor) {
    console.log(`Vendor « ${NAME} » trouvé chez Fleetbase : ${vendor.uuid}`);
    // Un Vendor préexistant peut être `inactive` — auquel cas la connexion de
    // l'opérateur serait refusée en `fleet_pending`, sans que rien n'explique
    // pourquoi puisque ce script vient d'annoncer un succès.
    if (vendor.status !== 'active') {
      console.log(`   Statut « ${vendor.status ?? 'non renseigné'} » → passage à « active »`);
      await api.put(`/int/v1/vendors/${vendor.uuid}`, { status: 'active' });
    }
  } else {
    console.log(`Création du Vendor « ${NAME} » chez Fleetbase…`);
    // `active` explicite, à l'inverse des entreprises tierces qui naissent
    // `inactive` en attendant un admin : celle-ci EST l'admin. Explicite quand
    // même — le modèle amont applique `$status ?? 'active'`, et se reposer sur
    // un défaut qu'on sait fragile est ce qui a produit le trou du Lot 4.
    const { data } = await api.post('/int/v1/vendors', {
      name: NAME,
      email: EMAIL || undefined,
      status: 'active',
    });
    vendor = data?.vendor ?? data;
    if (!vendor?.uuid) {
      throw new Error("Fleetbase n'a pas renvoyé d'uuid pour le Vendor créé");
    }
    vendorWasCreated = true;
    console.log(`Vendor créé : ${vendor.uuid}`);
  }

  // Sans identifiants, on enregistre quand même le prestataire — il sert à
  // désigner un facilitateur — mais avec un mot de passe **réellement**
  // aléatoire. `hrtime.bigint()` est un compteur monotone, pas une source
  // cryptographique : il aurait décrit une propriété qu'on n'avait pas.
  // Ce qui protège pour de bon reste `active: false`, relu à chaque requête.
  let fleet: { id: string; email: string };
  try {
    fleet = await prisma.fleetAccount.create({
      data: {
        email: EMAIL || `platform+${vendor.uuid}@echango.local`,
        password: await bcrypt.hash(
          hasCredentials ? PASSWORD : randomBytes(32).toString('hex'),
          10,
        ),
        businessName: NAME,
        fleetbaseVendorUuid: vendor.uuid,
        isPlatform: true,
        active: hasCredentials,
      },
    });
  } catch (error: any) {
    // Deux écritures, deux systèmes, aucune transaction commune — la règle 2 du
    // projet s'applique ici comme ailleurs. Sans compensation, un email déjà
    // pris laisserait un Vendor « Echango Delivery » orphelin, que le prochain
    // passage réutiliserait silencieusement.
    if (vendorWasCreated) {
      try {
        await api.delete(`/int/v1/vendors/${vendor.uuid}`);
        console.error(`   Vendor ${vendor.uuid} supprimé (compensation)`);
      } catch {
        console.error(
          `   ⚠️ Vendor ${vendor.uuid} orphelin chez Fleetbase — à supprimer en console.`,
        );
      }
    }
    throw error;
  }

  console.log(`✅ Prestataire plateforme enregistré : ${fleet.id}`);
  console.log(
    hasCredentials
      ? `   Compte opérateur actif : ${fleet.email}`
      : '   ⚠️ Aucun compte opérateur connectable (ECHANGO_PLATFORM_EMAIL/PASSWORD absents).\n' +
          '      Le prestataire existe et peut être désigné comme facilitateur ; la connexion\n' +
          '      viendra avec le persona opérateur (Lot 1).',
  );
}

main()
  .catch((error) => {
    console.error(`❌ ${error.message}`);
    process.exitCode = 1;
  })
  .finally(() => prisma.$disconnect());
