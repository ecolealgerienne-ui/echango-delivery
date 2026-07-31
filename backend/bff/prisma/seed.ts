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

  for (let page = 1; page <= 25; page++) {
    const { data } = await api.get('/int/v1/vendors', { params: { page, limit: pageSize } });
    const vendors: any[] = data?.vendors ?? data?.data ?? [];

    const found = vendors.find((v) => v?.name === name);
    if (found) return found;
    if (vendors.length < pageSize) return null;
  }

  throw new Error(
    `Recherche du Vendor « ${name} » tronquée après 25 pages — refus de créer un doublon.`,
  );
}

async function main() {
  const existing = await prisma.fleetAccount.findFirst({ where: { isPlatform: true } });

  if (existing) {
    console.log(
      `✅ Prestataire plateforme déjà en place : ${existing.businessName} ` +
        `(${existing.id}, vendor ${existing.fleetbaseVendorUuid})`,
    );
    return;
  }

  const api = fleetbase();

  let vendor = await findVendorByName(api, NAME);

  if (vendor) {
    console.log(`Vendor « ${NAME} » trouvé chez Fleetbase : ${vendor.uuid}`);
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
    console.log(`Vendor créé : ${vendor.uuid}`);
  }

  // Sans identifiants, on enregistre quand même le prestataire — il sert à
  // désigner un facilitateur — mais avec un mot de passe impossible à deviner
  // ET impossible à utiliser. Un compte opérateur se provisionne sciemment.
  const hasCredentials = EMAIL !== '' && PASSWORD.length >= MIN_PASSWORD_LENGTH;

  if (EMAIL !== '' && !hasCredentials) {
    throw new Error(
      `ECHANGO_PLATFORM_PASSWORD fait ${PASSWORD.length} caractères, minimum ` +
        `${MIN_PASSWORD_LENGTH}. Ce compte voit le registre de caisse de tout le réseau.`,
    );
  }

  const fleet = await prisma.fleetAccount.create({
    data: {
      email: EMAIL || `platform+${vendor.uuid}@echango.local`,
      // Un hash bcrypt d'une valeur aléatoire : aucune chaîne saisissable n'y
      // correspond, donc le compte existe sans être connectable.
      password: await bcrypt.hash(
        hasCredentials ? PASSWORD : `unusable-${vendor.uuid}-${process.hrtime.bigint()}`,
        10,
      ),
      businessName: NAME,
      fleetbaseVendorUuid: vendor.uuid,
      isPlatform: true,
      active: hasCredentials,
    },
  });

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
