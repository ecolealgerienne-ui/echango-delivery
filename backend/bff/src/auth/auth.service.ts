import {
  Injectable,
  BadRequestException,
  UnauthorizedException,
  ForbiddenException,
  Logger,
  ConflictException,
  HttpException,
} from '@nestjs/common';
import { jwtExpirationSeconds } from '../config/jwt';
import { badRequest, unauthorized, forbidden, conflict, notFound } from '../common/errors/http-errors';
import { AuditService } from '../common/audit/audit.service';
import { JwtService } from '@nestjs/jwt';
import { ConfigService } from '@nestjs/config';
import * as bcrypt from 'bcrypt';
import { createHash, randomBytes } from 'crypto';
import { PrismaService } from '../database/prisma.service';
import { FleetbaseApiClient } from '../fleetbase/fleetbase-api.client';
import {
  MerchantRegisterDto,
  MerchantLoginDto,
  FleetRegisterDto,
  FleetLoginDto,
  DriverRegisterDto,
  DriverLoginDto,
} from './dto/register.dto';

/**
 * Hash bcrypt d'une valeur arbitraire, comparé quand aucun compte n'existe.
 *
 * Sans lui, `loginUnified` ne payait un bcrypt que si la ligne existait :
 * email inconnu ≈ 5 ms, email connu ≈ 100 ms. Un écart d'un ordre de grandeur,
 * mesurable à travers Internet — donc un oracle d'énumération de comptes, alors
 * même que le commentaire du code affirmait le contraire (revue M7).
 *
 * Généré une fois au chargement du module : le coût est payé au démarrage, pas
 * à chaque requête.
 */
const DUMMY_HASH = bcrypt.hashSync('__no_such_account__', 10);

/**
 * Message unique pour tout échec d'authentification.
 *
 * `loginMerchant` distinguait « Email not verified » et « Account is inactive »
 * de « Invalid email or password » : trois messages, donc trois oracles
 * confirmant qu'un compte existe. L'utilisateur légitime, lui, apprend l'état
 * de son compte par un autre canal (support, email) — pas par un formulaire de
 * connexion anonyme.
 */
const INVALID_CREDENTIALS = 'Invalid email or password';

@Injectable()
export class AuthService {
  private readonly logger = new Logger(AuthService.name);

  constructor(
    private prisma: PrismaService,
    private jwtService: JwtService,
    private configService: ConfigService,
    private fleetbaseClient: FleetbaseApiClient,
    // `AuditModule` est `@Global()` : rien à importer dans `AuthModule`.
    private audit: AuditService,
  ) {}

  /**
   * Un email déjà pris : la réponse ne dépend pas du persona.
   *
   * Une seconde tentative après une inscription **en attente de validation**
   * doit dire la même chose que la première. Sans ce contrôle, le compte lisait
   * « en cours de validation », réessayait, et s'entendait répondre « email déjà
   * utilisé » — deux messages qui se contredisent sur le même fait, dont aucun
   * ne dit quoi faire.
   *
   * ⚠️ Les deux copies portaient chacune un commentaire disant « même raison que
   * côté commerçant » : c'est le signal exact de la règle 5 — la phrase avoue
   * l'invariant que rien ne tient. Un commentaire ne peut pas échouer.
   */
  private async assertEmailFree(
    existing: { fleetbaseVendorUuid: string } | null,
    persona: 'merchant' | 'fleet',
  ): Promise<void> {
    if (!existing) return;
    await this.assertVendorApproved(existing.fleetbaseVendorUuid, persona);
    conflict('auth.email_taken', 'Email already registered');
  }

  /**
   * Register a new merchant
   * Creates Echango account + Fleetbase Vendor + Customer
   */
  async registerMerchant(dto: MerchantRegisterDto) {
    // Check if email already exists
    const existing = await this.prisma.merchantAccount.findUnique({
      where: { email: dto.email },
    });

    await this.assertEmailFree(existing, 'merchant');

    // Retenu pour la compensation ci-dessous : une inscription qui échoue
    // après la création du Vendor laissait un enregistrement orphelin dans
    // Fleetbase, invisible du BFF et impossible à réutiliser — le `@unique` sur
    // `fleetbaseVendorUuid` n'y voit rien, et une seconde tentative avec le
    // même email recréait un second Vendor (revue archi #11).
    let createdVendorUuid: string | null = null;

    try {
      // 1. Create Vendor in Fleetbase
      this.logger.log(`Creating Vendor in Fleetbase for ${dto.businessName}`);
      // `inactive` et non le défaut : sans ce paramètre, le modèle Fleetbase
      // applique `$status ?? 'active'` et le commerçant serait validé à la
      // seconde de son inscription. La validation par un admin deviendrait
      // décorative — le pire des garde-fous, celui qui rassure sans protéger.
      //
      // `inactive` plutôt qu'un `pending` inventé : la console n'offre que
      // trois valeurs (active / inactive / suspended), et une quatrième
      // s'afficherait comme un champ vide dans son formulaire. Un admin verrait
      // un statut à remplir sans savoir ce qu'il écrase.
      const vendorResponse = await this.fleetbaseClient.createVendor(
        dto.businessName,
        dto.email,
        dto.businessPhone,
        'inactive',
      );

      const vendorUuid = vendorResponse.vendor?.uuid || vendorResponse.vendor?.id;
      if (!vendorUuid) {
        throw new Error('Vendor UUID not returned from Fleetbase');
      }
      createdVendorUuid = vendorUuid;

      // 2. Create Customer in Fleetbase
      this.logger.log(`Creating Customer in Fleetbase for vendor ${vendorUuid}`);
      const customerResponse = await this.fleetbaseClient.createCustomer(
        vendorUuid,
        dto.email,
        dto.firstName,
        dto.lastName,
      );

      const customerUuid = customerResponse.personnel?.contact_uuid || customerResponse.personnel?.contact?.uuid;
      if (!customerUuid) {
        throw new Error('Customer UUID not returned from Fleetbase');
      }

      // 3. Create MerchantAccount in BFF database
      const hashedPassword = await bcrypt.hash(dto.password, 10);

      const merchant = await this.prisma.merchantAccount.create({
        data: {
          email: dto.email,
          password: hashedPassword,
          // ⚠️ **Le profil n'est plus copié ici** (03/08/2026). Il vient
          // d'être écrit sur le `Vendor` et le `Contact` Fleetbase, juste
          // au-dessus — le recopier créait une seconde source qui se figeait à
          // l'inscription. `dto.firstName` & co. restent acceptés par le DTO :
          // ils servent à créer les objets amont, pas à être stockés ici.
          fleetbaseVendorUuid: vendorUuid,
          fleetbaseCustomerUuid: customerUuid,
          emailVerified: true, // TODO: Email verification in v2
        },
      });

      this.logger.log(
        `Demande d'inscription enregistrée : ${merchant.id} (en attente de validation)`,
      );
    } catch (error) {
      this.logger.error(`Merchant registration failed: ${error.message}`, error);
      await this.rollbackVendor(createdVendorUuid);

      const detail = error.response?.data ? JSON.stringify(error.response.data) : error.message;
      badRequest(
        'auth.merchant_registration_failed',
        this.configService.get('NODE_ENV') === 'development'
          ? `Failed to register merchant: ${detail}`
          : 'Failed to register merchant',
      );
    }

    // ⚠️ HORS du `try`, et ce n'est pas un détail de style : levée à
    // l'intérieur, cette exception serait attrapée par le filet ci-dessus, qui
    // appellerait `rollbackVendor()` et **supprimerait le commerçant qu'on
    // vient d'enregistrer**. La compensation ne doit défaire que les échecs,
    // jamais un succès qui se termine par un refus d'entrer.
    //
    // L'inscription ne délivre plus de jeton : le compte existe, l'accès n'est
    // pas encore ouvert. C'est exactement ce que « validation par un admin »
    // veut dire — sans quoi le nouveau commerçant entrait aussitôt, et la
    // validation ne portait sur rien.
    forbidden(
      'merchant_pending',
      'Votre demande a bien été enregistrée. Un administrateur Echango doit la valider ' +
        'avant votre première connexion.',
    );
  }

  /**
   * Compense la création d'un Vendor quand la suite de l'inscription échoue.
   *
   * L'inscription commerçant écrit dans deux systèmes sans transaction
   * commune : Fleetbase d'abord (Vendor puis Contact), le BFF ensuite. Un échec
   * à la deuxième ou troisième étape laissait un Vendor que plus rien ne
   * référençait — invisible du BFF, non réutilisable, et qu'une nouvelle
   * tentative avec le même email dupliquait au lieu de récupérer.
   *
   * La compensation est **best-effort et ne masque jamais l'erreur d'origine**
   * : si la suppression échoue à son tour, on le journalise avec l'uuid, pour
   * qu'un nettoyage manuel reste possible, et on laisse remonter l'échec
   * initial — c'est lui qui intéresse l'appelant.
   */
  private async rollbackVendor(vendorUuid: string | null): Promise<void> {
    if (!vendorUuid) return;

    try {
      await this.fleetbaseClient.deleteVendor(vendorUuid);
      this.logger.log(`Vendor ${vendorUuid} supprimé après échec d'inscription`);
    } catch (error) {
      this.logger.error(
        `Vendor ${vendorUuid} orphelin dans Fleetbase — suppression impossible : ${error.message}. ` +
          'À supprimer manuellement depuis la console Fleet-Ops.',
      );
    }
  }

  /**
   * Refuse la connexion tant qu'un admin n'a pas validé le compte.
   *
   * Vaut pour les **deux personas adossés à un `Vendor`** — commerçant et
   * entreprise de transport. Le mécanisme est identique ; seul le code de refus
   * change, parce que l'application ne dit pas la même phrase à un boulanger
   * qu'à une société de transport.
   *
   * ⚠️ Généralisé le 31/07/2026. Il n'a longtemps servi que le commerçant, et
   * `docs/specs_facilitateur.md` (première version) affirmait qu'il
   * « s'appliquait tel quel » à une entreprise : le mécanisme était réutilisable,
   * il n'était **pas branché**, et `loginFleet` ne lisait que sa colonne locale.
   * Écrire qu'un garde s'applique est exactement ce qui fait qu'on ne vérifie
   * jamais s'il est appelé.
   *
   * ── Où vit la décision ──────────────────────────────────────────────────
   *
   * Sur `Vendor.status` chez Fleetbase, et nulle part ailleurs. L'admin la
   * prend dans la console (Fleet-Ops → Fournisseurs → Statut), conformément à
   * la décision d'architecture : Fleetbase fait autorité, le BFF lit. Aucune
   * colonne locale ne recopie ce statut — ce serait précisément le miroir qu'on
   * vient de passer la journée à retirer.
   *
   * ── Le choix qui compte : que faire quand Fleetbase ne répond pas ────────
   *
   * On laisse passer, et on le journalise.
   *
   * Refuser serait plus strict et plus faux : une coupure réseau
   * déconnecterait **tous** les commerçants du réseau, y compris ceux validés
   * depuis des mois, et l'incident ressemblerait à une panne d'authentification
   * — la plus difficile à diagnostiquer sous pression.
   *
   * Le risque accepté est étroit : un commerçant non validé pourrait se
   * connecter pendant une indisponibilité de Fleetbase. Il n'y verrait pas
   * grand-chose, puisque toutes les données qui l'intéressent viennent de
   * Fleetbase, justement indisponible. Ce garde protège d'un abus à
   * l'inscription, pas d'un accès non autorisé aux données d'autrui — ce
   * dernier est assuré ailleurs, et sans dépendance réseau.
   */
  private async assertVendorApproved(
    vendorUuid: string,
    persona: 'merchant' | 'fleet' = 'merchant',
  ): Promise<void> {
    let vendor: any;
    try {
      vendor = await this.fleetbaseClient.getVendorByUuid(vendorUuid);
    } catch (error: any) {
      this.logger.warn(
        `Statut du vendor ${vendorUuid} illisible (${error.message}) — connexion autorisée ` +
          'par défaut : refuser déconnecterait aussi les commerçants déjà validés.',
      );
      return;
    }

    // Vendor introuvable : ne pas conclure d'une absence qu'il faut refuser.
    // Un vendor supprimé à la main côté Fleetbase priverait le commerçant de
    // son compte sans que personne ne l'ait décidé.
    if (!vendor) {
      this.logger.warn(
        `Vendor ${vendorUuid} introuvable chez Fleetbase — connexion autorisée, mais ce ` +
          'commerçant est orphelin et doit être rattaché ou supprimé.',
      );
      return;
    }

    if (vendor.status === 'active') return;

    this.logger.log(
      `Connexion refusée : vendor ${vendorUuid} au statut « ${vendor.status ?? 'non renseigné'} »`,
    );

    // Message explicite, et c'est délibéré alors que tous les autres refus de
    // connexion partagent `INVALID_CREDENTIALS`. La raison de l'uniformité est
    // de ne pas révéler qu'un compte existe ; ici l'appelant vient de prouver
    // qu'il connaît le mot de passe, donc il n'y a plus rien à lui cacher. Lui
    // renvoyer « identifiants invalides » l'enverrait réinitialiser un mot de
    // passe parfaitement bon.
    if (persona === 'fleet') {
      forbidden(
        'fleet_pending',
        'Votre entreprise est en cours de validation par Echango. Vous recevrez un accès ' +
          "dès qu'elle sera approuvée.",
      );
    }

    forbidden(
      'merchant_pending',
      'Votre compte est en cours de validation par Echango. Vous recevrez un accès dès ' +
        "qu'il sera approuvé.",
    );
  }

  /**
   * Login merchant with email/password
   */
  /**
   * Connexion unifiée : le serveur détermine le profil depuis l'email.
   *
   * Les trois personas ont chacun leur table et leur endpoint historique, mais
   * demander à l'utilisateur de choisir son profil avant de se connecter est
   * une friction inutile — et une information que le serveur possède déjà.
   *
   * Les trois tables sont interrogées et le mot de passe vérifié dans chacune,
   * sans court-circuit sur la première correspondance d'email : un même email
   * peut légitimement exister dans deux tables (un commerçant qui livre
   * lui-même), auquel cas seul le mot de passe tranche.
   *
   * Cas ambigu — même email ET même mot de passe dans plusieurs tables : on ne
   * choisit pas à la place de l'utilisateur, on renvoie les profils possibles
   * pour que l'app demande. Deviner reviendrait à ouvrir le mauvais espace.
   */
  async loginUnified(dto: MerchantLoginDto) {
    const matches: { role: string; login: () => Promise<any> }[] = [];

    const [merchant, driver, fleet] = await Promise.all([
      this.prisma.merchantAccount.findUnique({ where: { email: dto.email } }),
      this.prisma.driverAccount.findUnique({ where: { email: dto.email } }),
      this.prisma.fleetAccount.findUnique({ where: { email: dto.email } }),
    ]);

    // Chemin à coût constant : on compare TOUJOURS trois hashes, contre le
    // hash réel si le compte existe, contre DUMMY_HASH sinon. Le temps de
    // réponse ne dépend donc plus de l'existence du compte (revue M7).
    const [merchantOk, driverOk, fleetOk] = await Promise.all([
      bcrypt.compare(dto.password, merchant?.password ?? DUMMY_HASH),
      bcrypt.compare(dto.password, driver?.password ?? DUMMY_HASH),
      bcrypt.compare(dto.password, fleet?.password ?? DUMMY_HASH),
    ]);

    if (merchant && merchantOk) {
      matches.push({ role: 'merchant', login: () => this.loginMerchant(dto) });
    }
    if (driver && driverOk) {
      matches.push({ role: 'transporteur', login: () => this.loginDriver(dto) });
    }
    if (fleet && fleetOk) {
      matches.push({ role: 'fleet', login: () => this.loginFleet(dto) });
    }

    if (matches.length === 0) {
      unauthorized('auth.invalid_credentials', INVALID_CREDENTIALS);
    }

    // Un même email peut légitimement valoir pour deux profils (un commerçant
    // qui livre lui-même). On ne choisit pas à sa place : ouvrir le mauvais
    // espace serait pire qu'une question.
    if (matches.length > 1) {
      return {
        requiresRoleSelection: true,
        roles: matches.map((m) => m.role),
      };
    }

    const result = await matches[0].login();

    // Exposer le profil résolu : sans lui, le client devrait le déduire de la
    // forme du payload, ce qui reviendrait à deviner.
    return { ...result, user: { ...result.user, type: matches[0].role } };
  }


  async loginMerchant(dto: MerchantLoginDto) {
    const merchant = await this.prisma.merchantAccount.findUnique({
      where: { email: dto.email },
    });

    if (!merchant) {
      unauthorized('auth.invalid_credentials', INVALID_CREDENTIALS);
    }

    const passwordMatches = await bcrypt.compare(dto.password, merchant.password);

    if (!passwordMatches) {
      unauthorized('auth.invalid_credentials', INVALID_CREDENTIALS);
    }

    if (!merchant.emailVerified) {
      unauthorized('auth.invalid_credentials', INVALID_CREDENTIALS);
    }

    if (!merchant.active) {
      unauthorized('auth.invalid_credentials', INVALID_CREDENTIALS);
    }

    await this.assertVendorApproved(merchant.fleetbaseVendorUuid, 'merchant');

    // Update last login
    await this.prisma.merchantAccount.update({
      where: { id: merchant.id },
      data: { lastLoginAt: new Date() },
    });

    this.logger.log(`Merchant logged in: ${merchant.id}`);

    // Generate JWT token
    const token = this.generateToken(merchant.id, merchant.email, 'merchant', merchant.tokenVersion);

    // ⚠️ **Le nom vient du `Vendor` Fleetbase**, plus d'une copie locale figée
    // à l'inscription (03/08/2026). C'est le seul champ de profil que
    // l'application lit réellement — `authState.displayName` en fait le titre
    // de l'écran commerçant.
    //
    // ⚠️ Un appel Fleetbase de plus sur le chemin de connexion, assumé : la
    // route est plafonnée à 5/min, et la disponibilité de Fleetbase est un
    // prérequis du produit (décision du 03/08/2026). `getVendorIdentity` rend
    // `null` sans lever — un nom illisible ne doit pas empêcher de se
    // connecter.
    const identite = await this.fleetbaseClient.getVendorIdentity(
      merchant.fleetbaseVendorUuid,
    );

    return {
      token,
      user: {
        id: merchant.id,
        email: merchant.email,
        businessName: identite?.name ?? null,
      },
    };
  }

  /**
   * Register a new fleet manager ("petite flotte" persona).
   * Creates Echango account + Fleetbase Vendor only - no Customer/personnel,
   * no dedicated Fleetbase User (Option A, docs/specs_bff.md §2): the fleet
   * manager authenticates purely against the BFF, which then acts as a
   * service account against FleetOps, scoping every call by this Vendor's uuid.
   *
   * ⚠️ Le scoping est aujourd'hui appliqué **en mémoire** côté BFF. Le motif
   * historique (« Fleetbase n'applique pas ces filtres ») était une erreur de
   * nom de paramètre : `facilitator` et `vendor` fonctionnent, `facilitator_uuid`
   * et `vendor_uuid` n'existent pas. Voir `docs/architecture_bff_fleetbase.md`
   * §4.3.
   */
  async registerFleet(dto: FleetRegisterDto) {
    const existing = await this.prisma.fleetAccount.findUnique({
      where: { email: dto.email },
    });

    await this.assertEmailFree(existing, 'fleet');

    // Même compensation que côté commerçant : sans elle, un échec après la
    // création du Vendor laissait un enregistrement orphelin que le `@unique`
    // sur `fleetbaseVendorUuid` ne voit pas, et qu'une seconde tentative avec le
    // même email dupliquait au lieu de récupérer.
    let createdVendorUuid: string | null = null;

    try {
      this.logger.log(`Creating Vendor in Fleetbase for fleet ${dto.businessName}`);
      // `inactive` explicite, exactement pour la raison trouvée sur le
      // commerçant au Lot 4 : sans ce paramètre, le modèle Fleetbase applique
      // `$status ?? 'active'` et **chaque entreprise de transport naîtrait
      // validée**. Le garde ajouté à `loginFleet` ci-dessous aurait alors été
      // livré sans rien empêcher — un garde-fou qui rassure sans protéger.
      const vendorResponse = await this.fleetbaseClient.createVendor(
        dto.businessName,
        dto.email,
        dto.businessPhone,
        'inactive',
      );

      const vendorUuid = vendorResponse.vendor?.uuid || vendorResponse.vendor?.id;
      if (!vendorUuid) {
        throw new Error('Vendor UUID not returned from Fleetbase');
      }
      createdVendorUuid = vendorUuid;

      const hashedPassword = await bcrypt.hash(dto.password, 10);

      const fleet = await this.prisma.fleetAccount.create({
        data: {
          email: dto.email,
          password: hashedPassword,
          // ⚠️ **Le profil n'est plus copié ici** (03/08/2026). Il vient
          // d'être écrit sur le `Vendor` et le `Contact` Fleetbase, juste
          // au-dessus — le recopier créait une seconde source qui se figeait à
          // l'inscription. `dto.firstName` & co. restent acceptés par le DTO :
          // ils servent à créer les objets amont, pas à être stockés ici.
          fleetbaseVendorUuid: vendorUuid,
        },
      });

      this.logger.log(
        `Demande d'inscription entreprise enregistrée : ${fleet.id} (en attente de validation)`,
      );
    } catch (error) {
      // Laissez-passer : aucun refus métier ne naît dans ce `try` aujourd'hui,
      // mais le jour où quelqu'un y ajoute un `conflict()`, il serait avalé
      // **et** déclencherait `rollbackVendor()` — donc supprimerait un Vendor
      // légitime en réponse à un refus. Trois lignes qui ferment un piège que
      // ce fichier commente déjà deux fois.
      if (error instanceof HttpException) {
        throw error;
      }
      await this.rollbackVendor(createdVendorUuid);
      this.logger.error(`Fleet registration failed: ${error.message}`, error);
      const detail = error.response?.data ? JSON.stringify(error.response.data) : error.message;
      badRequest(
        'auth.fleet_registration_failed',
        this.configService.get('NODE_ENV') === 'development'
          ? `Failed to register fleet account: ${detail}`
          : 'Failed to register fleet account',
      );
    }

    // ⚠️ HORS du `try`, comme côté commerçant, et pour la même raison : levée à
    // l'intérieur, cette exception serait attrapée par le filet ci-dessus, qui
    // appellerait `rollbackVendor()` et **supprimerait l'entreprise qu'on vient
    // d'enregistrer**. La compensation ne défait que les échecs, jamais un
    // succès qui se termine par un refus d'entrer.
    //
    // Plus de jeton à l'inscription : c'était le second trou du Lot 4, resté
    // ouvert côté flotte. Le délivrer aurait fait entrer l'entreprise
    // immédiatement, et le garde n'aurait servi qu'à sa deuxième visite.
    forbidden(
      'fleet_pending',
      'Votre demande a bien été enregistrée. Un administrateur Echango doit valider votre ' +
        'entreprise avant votre première connexion.',
    );
  }

  /**
   * Login fleet manager with email/password
   */
  async loginFleet(dto: FleetLoginDto) {
    const fleet = await this.prisma.fleetAccount.findUnique({
      where: { email: dto.email },
    });

    if (!fleet) {
      unauthorized('auth.invalid_credentials', INVALID_CREDENTIALS);
    }

    const passwordMatches = await bcrypt.compare(dto.password, fleet.password);

    if (!passwordMatches) {
      unauthorized('auth.invalid_credentials', INVALID_CREDENTIALS);
    }

    // `active` et `Vendor.status` ne disent pas la même chose, et ce n'est donc
    // pas l'état parallèle qu'on pourrait y voir. `Vendor.status` porte la
    // **validation** — décidée par un admin dans la console, chez Fleetbase qui
    // fait autorité. `active` est notre **coupe-circuit applicatif**, immédiat
    // et local, que Fleetbase ne peut pas exprimer parce qu'il ne connaît pas
    // nos comptes. Les trois personas portent déjà ce même couple : le
    // commerçant l'a depuis le Lot 4, sans que personne y ait vu un doublon.
    if (!fleet.active) {
      unauthorized('auth.invalid_credentials', INVALID_CREDENTIALS);
    }

    await this.assertVendorApproved(fleet.fleetbaseVendorUuid, 'fleet');

    await this.prisma.fleetAccount.update({
      where: { id: fleet.id },
      data: { lastLoginAt: new Date() },
    });

    this.logger.log(`Fleet manager logged in: ${fleet.id}`);

    const token = this.generateToken(fleet.id, fleet.email, 'fleet', fleet.tokenVersion);

    // Même motif que pour le commerçant : le nom vit sur le `Vendor`.
    const identiteFlotte = await this.fleetbaseClient.getVendorIdentity(
      fleet.fleetbaseVendorUuid,
    );

    return {
      token,
      user: {
        id: fleet.id,
        email: fleet.email,
        businessName: identiteFlotte?.name ?? null,
      },
    };
  }

  /**
   * Hachage du jeton d'invitation.
   *
   * SHA-256 sans sel suffit ici, contrairement à un mot de passe : le jeton
   * fait 32 octets aléatoires, il n'est ni deviné ni réutilisé ailleurs. Ce
   * qu'on veut, c'est qu'une fuite de la base ne livre pas d'invitations
   * utilisables.
   */
  private hashInvitationToken(token: string): string {
    return createHash('sha256').update(token).digest('hex');
  }

  /**
   * Traduit les deux pannes d'installation Prisma en message actionnable.
   *
   * Elles sont indiscernables les unes des autres dans un 500 nu, et aucune ne
   * vient de l'appelant :
   *
   * - `P2021` — table absente : migration jamais jouée ;
   * - `P2022` — colonne absente : `prisma generate` a été lancé mais pas la
   *   migration, donc le client réclame des colonnes que la base n'a pas.
   *   Piège particulier : la requête qui casse n'a rien à voir avec la colonne
   *   ajoutée, puisque le client sélectionne toutes les colonnes du modèle ;
   * - modèle `undefined` — l'inverse : migration jouée, client pas régénéré.
   *
   * Toutes se corrigent côté serveur en une commande, et frappent au premier
   * appel d'un chemin neuf. D'où le réflexe de brancher ceci sur toute route
   * touchant un modèle récemment modifié, plutôt que de laisser un 500 opaque
   * le jour du test.
   */
  private rethrowIfPrismaSetupIssue(error: any, ...modelNames: string[]): void {
    const message = error?.message ?? '';
    const looksUndefined = modelNames.some((m) =>
      new RegExp(`${m}|Cannot read properties of undefined`, 'i').test(message),
    );

    if (['P2021', 'P2022'].includes(error?.code) || looksUndefined) {
      badRequest(
        'server.schema_out_of_sync',
        `Schéma Prisma désynchronisé (modèles concernés : ${modelNames.join(', ')}). ` +
          'Lancer : npm run prisma:migrate PUIS npm run prisma:generate. ' +
          `Détail : ${message.split('\n').pop()}`,
      );
    }
  }

  /**
   * Émet une invitation pour un Driver Fleetbase donné (action opérateur).
   *
   * Le jeton en clair n'est renvoyé qu'ici, une seule fois : la base n'en
   * garde que l'empreinte. À transmettre au transporteur hors bande.
   */
  async createDriverInvitation(
    fleetId: string,
    fleetbaseDriverUuid: string,
    email?: string,
    validForDays = 7,
  ) {
    // ⚠️ Résolu et refusé **AVANT** le `try` : le `catch` ci-dessous réemballe
    // en `auth.driver_invitation_failed`, ce qui remplacerait un refus délibéré
    // par « émission impossible » et ferait disparaître le code que l'app doit
    // traduire. Piège nommé en règle 3 de CLAUDE.md, rencontré trois fois.
    await this.assertDriverBelongsToFleet(fleetId, fleetbaseDriverUuid);

    const token = randomBytes(32).toString('base64url');
    const expiresAt = new Date(Date.now() + validForDays * 24 * 60 * 60 * 1000);

    try {
      const existing = await this.prisma.driverAccount.findUnique({
        where: { fleetbaseDriverUuid },
      });
      if (existing) {
        conflict('auth.driver_already_has_account', 'This driver already has an Echango account');
      }

      await this.prisma.driverInvitation.create({
        data: {
          tokenHash: this.hashInvitationToken(token),
          fleetbaseDriverUuid,
          email,
          expiresAt,
        },
      });
    } catch (error) {
      if (error instanceof ConflictException) {
        throw error;
      }
      this.logger.error(`Driver invitation failed: ${error.message}`, error);
      this.rethrowIfPrismaSetupIssue(error, 'driverInvitation', 'driverAccount');
      badRequest(
        'auth.driver_invitation_failed',
        this.configService.get('NODE_ENV') === 'development'
          ? `Émission d'invitation impossible : ${error.message}`
          : 'Could not issue driver invitation',
      );
    }

    // Le refus était audité, pas le succès — or c'est le succès qui crée un
    // jeton donnant l'identité de quelqu'un. `DriverInvitation` ne stocke pas
    // son émetteur : cette entrée est le **seul** lien entre une invitation et
    // l'entreprise qui l'a demandée.
    this.audit.succeeded({
      actorType: 'fleet',
      actorId: fleetId,
      action: 'driver.invitation',
      resourceType: 'Driver',
      resourceId: fleetbaseDriverUuid,
    });

    this.logger.log(`Driver invitation issued for ${fleetbaseDriverUuid} by fleet ${fleetId}`);

    return { invitationToken: token, expiresAt };
  }

  /**
   * Ce conducteur appartient-il bien à l'entreprise qui l'invite ?
   *
   * ── Pourquoi ce contrôle manquait, et ce qu'il coûtait ────────────────────
   *
   * `@Persona('fleet')` répond à « qui a le droit d'émettre une invitation ».
   * Il ne dit rien de « pour quel conducteur », et la méthode ne recevait même
   * pas l'identité de l'appelant. Un compte flotte pouvait donc inviter
   * n'importe quel `Driver` du réseau pas encore inscrit — les uuid sortent
   * dans `ORDER_LINK_FIELDS` de toute commande — puis créer son compte Echango
   * à sa place et récupérer ses courses, ses preuves et son registre de caisse.
   *
   * ── Le cas du pool, qui n'est pas une exception ───────────────────────────
   *
   * Un conducteur sans `vendor_uuid` n'appartient à aucune entreprise : il est
   * du pool, et le pool est Echango (`specs_facilitateur.md` §2.2). Seul le
   * prestataire plateforme peut donc l'inviter. Ce n'est pas un passe-droit,
   * c'est la même règle lue sur le même champ — Echango est le facilitateur de
   * ceux que personne n'a rattachés.
   */
  private async assertDriverBelongsToFleet(
    fleetId: string,
    fleetbaseDriverUuid: string,
  ): Promise<void> {
    const fleet = await this.prisma.fleetAccount.findUnique({ where: { id: fleetId } });
    if (!fleet) {
      notFound('fleet.not_found', 'Fleet account not found');
    }

    let driver: any;
    try {
      driver = await this.fleetbaseClient.getDriverByUuid(fleetbaseDriverUuid);
    } catch (error: any) {
      // Contrairement à `assertVendorApproved`, une lecture impossible **refuse**
      // ici. Les deux gardes n'ont pas le même sens de l'échec : refuser une
      // connexion couperait des comptes déjà validés, alors que refuser une
      // émission d'invitation ne fait que la reporter. Sur un doute, on ne
      // délivre pas un jeton qui donne l'identité de quelqu'un.
      this.logger.error(
        `Conducteur ${fleetbaseDriverUuid} illisible (${error.message}) — invitation refusée`,
      );
      badRequest(
        'auth.driver_invitation_failed',
        "Impossible de vérifier ce transporteur pour le moment. Réessayez.",
      );
    }

    if (!driver) {
      notFound('auth.driver_not_found', 'Driver not found in Fleetbase');
    }

    // ⚠️ **Champ absent ≠ conducteur non rattaché**, et confondre les deux
    // casserait ce garde dans les deux sens à la fois.
    //
    // Le seul endroit du dépôt qui lisait `vendor_uuid` jusqu'ici le lisait sur
    // la réponse de **liste** (`flotte.service.ts`). Rien n'établit que la
    // ressource **unitaire** l'expose : ce projet a déjà rencontré une ressource
    // d'index et une ressource complète divergentes (`_index_resource`), et une
    // résolution d'identifiant non uniforme route par route.
    //
    // Si le champ manquait et qu'on lisait `?? null`, alors : plus aucune
    // entreprise ne pourrait inviter son propre conducteur (403 systématique),
    // et le prestataire plateforme pourrait inviter n'importe qui — le tout sans
    // une seule erreur pour le signaler. D'où la distinction explicite entre
    // « absent » et « nul », et le repli sur la liste, dont on SAIT qu'elle
    // porte le champ.
    let vendorUuid: string | null;

    if ('vendor_uuid' in driver) {
      vendorUuid = driver.vendor_uuid || null;
    } else {
      this.logger.warn(
        `La lecture unitaire du conducteur ${fleetbaseDriverUuid} ne porte pas vendor_uuid — ` +
          'repli sur la liste filtrée par fournisseur',
      );
      vendorUuid = await this.readDriverVendorFromList(
        fleetbaseDriverUuid,
        fleet.fleetbaseVendorUuid,
      );
    }

    // `fleetbaseVendorUuid` vide rendrait `isOwn` vrai pour tout conducteur sans
    // fournisseur. Aucun chemin actuel ne le permet — les deux créateurs lèvent
    // si l'uuid manque — mais rien ne l'interdit en base.
    const isOwn =
      !!fleet.fleetbaseVendorUuid && vendorUuid === fleet.fleetbaseVendorUuid;
    const isUnattachedPoolDriver = vendorUuid === null && fleet.isPlatform === true;

    if (isOwn || isUnattachedPoolDriver) return;

    this.audit.denied({
      actorType: 'fleet',
      actorId: fleetId,
      action: 'driver.invitation',
      resourceType: 'Driver',
      resourceId: fleetbaseDriverUuid,
      reason: 'Conducteur rattaché à une autre entreprise, ou pool sans droit plateforme',
    });

    forbidden(
      'auth.driver_not_in_fleet',
      "Ce transporteur n'appartient pas à votre entreprise.",
    );
  }

  /**
   * Repli quand la lecture unitaire d'un conducteur ne porte pas `vendor_uuid`.
   *
   * `GET /drivers?vendor=<uuid>` est le filtre que le module flotte utilise
   * depuis le Lot 1, et sa réponse porte le champ — c'est de là que venait la
   * seule lecture connue. On demande donc « les conducteurs de CETTE
   * entreprise » et on regarde si le nôtre y est.
   *
   * Rend l'uuid du fournisseur si le conducteur appartient à l'entreprise
   * interrogée, `null` sinon. `null` signifie donc ici « pas à cette
   * entreprise-là », ce qui suffit au seul appelant : il n'a pas besoin de
   * savoir à qui d'autre, il a besoin de savoir si c'est à lui.
   *
   * ⚠️ Conséquence à connaître : dans ce repli, un conducteur rattaché à une
   * AUTRE entreprise et un conducteur du pool deviennent indiscernables. Le
   * prestataire plateforme pourrait donc inviter un conducteur d'une entreprise
   * tierce. C'est pourquoi ce chemin journalise en `warn` : il est un filet, pas
   * un mode de fonctionnement, et le contrôle qui le rend inutile tient en un
   * `curl` (voir `docs/specs_facilitateur.md` §12).
   */
  private async readDriverVendorFromList(
    fleetbaseDriverUuid: string,
    vendorUuid: string,
  ): Promise<string | null> {
    try {
      // Paginé : la version précédente lisait une seule page. Un conducteur
      // au-delà était déclaré ne PAS appartenir à l'entreprise, et son
      // invitation refusée — un refus de sécurité pour une raison qui n'en
      // était pas une, sans rien à l'écran pour le distinguer d'un vrai.
      const drivers = await this.fleetbaseClient.fetchEveryDriverMatching({
        vendor: vendorUuid,
      });
      const found = drivers.some((d: any) => d?.uuid === fleetbaseDriverUuid);
      return found ? vendorUuid : null;
    } catch (error: any) {
      this.logger.error(
        `Repli sur la liste des conducteurs impossible (${error.message}) — invitation refusée`,
      );
      badRequest(
        'auth.driver_invitation_failed',
        'Impossible de vérifier ce transporteur pour le moment. Réessayez.',
      );
    }
  }

  /**
   * Register (link) an Echango driver account to an already-provisioned
   * Fleetbase Driver. Unlike merchant/fleet registration, this never creates
   * anything in Fleetbase itself - the Driver must already exist (manual
   * provisioning, docs/specs_app_transporteur.md §2.1/§13 Q8). We still
   * verify the given uuid resolves to a real Driver before linking, rather
   * than trusting it blindly, and capture its `user_uuid` (needed later to
   * route push tokens through UserDevice, see fleetbase-api.client.ts
   * upsertDriverDeviceToken).
   *
   * Uses getAllDrivers() + a client-side find rather than a single-record
   * GET: docs/journal_implementation_bff.md §2.13 found that `GET
   * /drivers/{uuid}` ignores the path param entirely and returns the full
   * company driver list regardless, so a per-id lookup would silently "find"
   * any uuid, including typos - fetching everything and matching ourselves
   * is the only way to actually confirm the uuid is real.
   */
  async registerDriver(dto: DriverRegisterDto) {
    try {
      // Ces deux vérifications sont volontairement DANS le try : hors du try,
      // une erreur Prisma (table absente, client non régénéré) échappe au
      // filtre d'exceptions — qui ne capture que les HttpException — et sort
      // en 500 "Internal server error" sans le moindre indice exploitable.
      const existingEmail = await this.prisma.driverAccount.findUnique({
        where: { email: dto.email },
      });

      if (existingEmail) {
        conflict('auth.email_taken', 'Email already registered');
      }

      // Le driver visé vient de l'INVITATION, jamais de la requête : c'est
      // toute la correction de C2. Un appelant ne peut plus désigner le
      // transporteur qu'il souhaite devenir.
      const invitation = await this.prisma.driverInvitation.findUnique({
        where: { tokenHash: this.hashInvitationToken(dto.invitationToken) },
      });

      // Message identique pour un jeton inconnu, expiré ou déjà consommé :
      // aucun de ces cas ne doit permettre de sonder les invitations valides.
      const invitationValid =
        invitation && !invitation.usedAt && invitation.expiresAt > new Date();

      if (!invitationValid) {
        badRequest('auth.invitation_invalid', 'Invitation invalide ou expirée');
      }

      // Une invitation nominative ne vaut que pour l'email visé.
      if (invitation.email && invitation.email.toLowerCase() !== dto.email.toLowerCase()) {
        badRequest('auth.invitation_invalid', 'Invitation invalide ou expirée');
      }

      const existingUuid = await this.prisma.driverAccount.findUnique({
        where: { fleetbaseDriverUuid: invitation.fleetbaseDriverUuid },
      });

      if (existingUuid) {
        conflict('auth.driver_already_linked', 'This driver is already linked to an account');
      }

      // Lecture unitaire (journal §24). Elle compare l'uuid renvoyé à celui
      // demandé, ce qui compte particulièrement ici : ce que cet appel ramène
      // détermine à quel transporteur le nouveau compte sera rattaché.
      const fleetbaseDriver = await this.fleetbaseClient.getDriverByUuid(
        invitation.fleetbaseDriverUuid,
      );

      if (!fleetbaseDriver) {
        badRequest('auth.driver_unknown', 'Unknown Fleetbase driver UUID - ask an operator to verify provisioning');
      }

      const hashedPassword = await bcrypt.hash(dto.password, 10);

      const driver = await this.prisma.driverAccount.create({
        data: {
          email: dto.email,
          password: hashedPassword,
          // ⚠️ **Nom et téléphone ne sont plus copiés ici** (03/08/2026). Le
          // conducteur EXISTE déjà chez Fleetbase — l'invitation porte son
          // uuid — donc son identité y est, et la recopier créait une seconde
          // copie qui se figeait à l'inscription. Mesurée le même jour : elle
          // divergeait sur **trois conducteurs sur trois**.
          //
          // `dto.firstName`/`lastName`/`phone` restent acceptés par le DTO :
          // ils servent au formulaire, pas au stockage.
          fleetbaseDriverUuid: invitation.fleetbaseDriverUuid,
          fleetbaseUserUuid: fleetbaseDriver.user_uuid || null,
          fleetbaseDriverPublicId: fleetbaseDriver.public_id || null,
        },
      });

      // Consommée après coup : si la création du compte échoue, l'invitation
      // reste utilisable plutôt que d'être perdue pour le transporteur.
      await this.prisma.driverInvitation.update({
        where: { id: invitation.id },
        data: { usedAt: new Date() },
      });

      this.logger.log(`Driver account registered: ${driver.id}`);

      const token = this.generateToken(driver.id, driver.email, 'transporteur', driver.tokenVersion);

      return {
        token,
        // ⚠️ **Sans nom depuis le 03/08/2026**, et c'est vérifié plutôt que
        // supposé : l'application ne lit `user.firstName` nulle part, et
        // `authState.displayName` ne sert qu'au titre de l'écran COMMERÇANT.
        // Les servir aurait imposé un appel Fleetbase sur le chemin de
        // connexion pour un champ que personne n'affiche.
        user: { id: driver.id, email: driver.email },
      };
    } catch (error) {
      if (error instanceof BadRequestException || error instanceof ConflictException) {
        throw error;
      }
      this.logger.error(`Driver registration failed: ${error.message}`, error);

      this.rethrowIfPrismaSetupIssue(error, 'driverAccount');

      const detail = error.response?.data ? JSON.stringify(error.response.data) : error.message;
      badRequest(
        'auth.driver_registration_failed',
        this.configService.get('NODE_ENV') === 'development'
          ? `Failed to register driver: ${detail}`
          : 'Failed to register driver',
      );
    }
  }

  /**
   * Login driver with email/password
   */
  async loginDriver(dto: DriverLoginDto) {
    const driver = await this.prisma.driverAccount.findUnique({
      where: { email: dto.email },
    });

    if (!driver) {
      unauthorized('auth.invalid_credentials', INVALID_CREDENTIALS);
    }

    const passwordMatches = await bcrypt.compare(dto.password, driver.password);

    if (!passwordMatches) {
      unauthorized('auth.invalid_credentials', INVALID_CREDENTIALS);
    }

    if (!driver.active) {
      unauthorized('auth.invalid_credentials', INVALID_CREDENTIALS);
    }

    await this.prisma.driverAccount.update({
      where: { id: driver.id },
      data: { lastLoginAt: new Date() },
    });

    this.logger.log(`Driver logged in: ${driver.id}`);

    const token = this.generateToken(driver.id, driver.email, 'transporteur', driver.tokenVersion);

    return {
      token,
      // Même motif qu'à l'inscription : aucun lecteur côté application.
      user: { id: driver.id, email: driver.email },
    };
  }

  /**
   * Register a driver's push token. Kept separate from the merchant
   * registerDeviceToken below (different Prisma model - DriverDeviceToken vs
   * DeviceToken - since DeviceToken is hard-wired to MerchantAccount).
   *
   * Also mirrors the token to Fleetbase as a UserDevice record so the native
   * OrderPing FCM/APN channel (docs/specs_echango_delivery.md §3.2) can reach
   * this device directly (see fleetbase-api.client.ts
   * upsertDriverDeviceToken for the full discovery notes on why this targets
   * UserDevice rather than the Driver record). The mirror is best-effort: if
   * it fails, the local token is still saved and REST polling keeps working,
   * only native push delivery is affected - so we log and continue rather
   * than failing the whole request.
   */
  async registerDriverDeviceToken(driverId: string, token: string, platform: string) {
    const driver = await this.prisma.driverAccount.findUnique({
      where: { id: driverId },
    });

    if (!driver) {
      badRequest('auth.driver_not_found', 'Driver not found');
    }

    const existing = await this.prisma.driverDeviceToken.findUnique({
      where: { token },
    });

    let record = existing;

    if (existing) {
      if (existing.driverId !== driverId) {
        record = await this.prisma.driverDeviceToken.update({
          where: { id: existing.id },
          data: { driverId, active: true },
        });
      }
    } else {
      record = await this.prisma.driverDeviceToken.create({
        data: { driverId, token, platform },
      });
    }

    // Retire this driver's other tokens before registering the new one.
    //
    // Firebase hands back a different token after a reinstall, cleared app
    // data or a restored backup. Nothing deletes the previous UserDevice, and
    // Driver::routeNotificationForFcm() returns every device on the user_uuid
    // — so without this, Fleetbase accumulates dead tokens and keeps pushing
    // to them indefinitely. Nothing errors; the notifications simply never
    // arrive, which is the hardest kind of failure to notice in production.
    const stale = await this.prisma.driverDeviceToken.findMany({
      where: { driverId, active: true, token: { not: token } },
    });

    for (const old of stale) {
      if (old.fleetbaseUserDeviceUuid) {
        // uuid first, public_id as fallback — the opposite of the /v1 routes.
        // Established by testing on 28/07/2026: DELETE /int/v1/user-devices/
        // {public_id} answers 404 "User Device not found", while the uuid
        // works. So resolution is NOT uniform across Fleetbase: the public v1
        // API resolves by public_id (§6.7), this internal route by uuid.
        // Both are tried rather than trusting either, since that assumption
        // has now been wrong in both directions.
        const candidates: string[] = [old.fleetbaseUserDeviceUuid];

        let deleted = false;
        for (const id of candidates) {
          try {
            await this.fleetbaseClient.deleteUserDevice(id);
            deleted = true;
            break;
          } catch {
            // Try the next identifier before giving up.
          }
        }

        // Only pay for a lookup if the stored identifier did not work.
        if (!deleted) {
          const device = await this.fleetbaseClient.findUserDeviceByToken(old.token);
          if (device?.public_id) {
            try {
              await this.fleetbaseClient.deleteUserDevice(device.public_id);
              deleted = true;
            } catch {
              // Fall through to the warning below.
            }
          }
        }

        if (!deleted) {
          // Best-effort: a device we cannot delete must not block the new one
          // from being registered, or the driver stops receiving anything.
          this.logger.warn(
            `Could not delete stale Fleetbase UserDevice (tried: ${candidates.join(', ') || 'none'})`,
          );
        }
      }
      await this.prisma.driverDeviceToken.update({
        where: { id: old.id },
        data: { active: false },
      });
    }

    if (stale.length) {
      this.logger.log(`Retired ${stale.length} stale push token(s) for driver ${driverId}`);
    }

    if (driver.fleetbaseUserUuid && !record.fleetbaseUserDeviceUuid) {
      try {
        const response = await this.fleetbaseClient.upsertDriverDeviceToken(
          driver.fleetbaseUserUuid,
          token,
          platform,
        );
        const userDeviceUuid = response?.user_device?.uuid || response?.data?.uuid;

        if (userDeviceUuid) {
          record = await this.prisma.driverDeviceToken.update({
            where: { id: record.id },
            data: { fleetbaseUserDeviceUuid: userDeviceUuid },
          });
        }
      } catch (error) {
        this.logger.warn(
          `Failed to mirror device token to Fleetbase UserDevice for driver ${driverId}: ${error.message}`,
        );
      }
    }

    return record;
  }

  /**
   * Register device token for push notifications
   */
  async registerDeviceToken(merchantId: string, token: string, platform: string) {
    const merchant = await this.prisma.merchantAccount.findUnique({
      where: { id: merchantId },
    });

    if (!merchant) {
      badRequest('auth.merchant_not_found', 'Merchant not found');
    }

    // Check if token already exists
    const existing = await this.prisma.deviceToken.findUnique({
      where: { token },
    });

    if (existing) {
      // Update if merchant changed
      if (existing.merchantId !== merchantId) {
        await this.prisma.deviceToken.update({
          where: { id: existing.id },
          data: { merchantId },
        });
      }
      return existing;
    }

    // Create new device token
    return this.prisma.deviceToken.create({
      data: {
        merchantId,
        token,
        platform,
      },
    });
  }

  // ⚠️ `verifyToken(token)` a été SUPPRIMÉ le 03/08/2026 — jamais appelé.
  //
  // `POST /auth/verify` porte le même nom dans le contrôleur, ce qui l'a fait
  // passer pour employé : elle rend `{valid: true, user: req.user}`, le garde
  // global ayant déjà validé le jeton. La vérification réelle vit dans
  // `JwtAuthGuard`, et c'est le bon endroit — une seconde implémentation aurait
  // pu diverger de celle qui protège réellement les routes.

  /**
   * Generate JWT token
   */
  /**
   * Révoque toutes les sessions ouvertes du compte appelant.
   *
   * Incrémenter `tokenVersion` suffit : le garde compare la valeur portée par
   * chaque jeton à celle du compte, donc tous les jetons déjà émis — y compris
   * celui qui vient de servir à demander la révocation — cessent d'être
   * acceptés immédiatement.
   *
   * C'est le geste utile après un téléphone perdu ou un doute sur un mot de
   * passe. À rappeler depuis un futur changement de mot de passe : sans ça,
   * changer son mot de passe laisserait valides les jetons émis avec l'ancien.
   */
  async revokeAllSessions(userId: string, type: string) {
    const data = { tokenVersion: { increment: 1 } };

    switch (type) {
      case 'transporteur':
        await this.prisma.driverAccount.update({ where: { id: userId }, data });
        break;
      case 'merchant':
        await this.prisma.merchantAccount.update({ where: { id: userId }, data });
        break;
      case 'fleet':
        await this.prisma.fleetAccount.update({ where: { id: userId }, data });
        break;
      default:
        badRequest('server.invalid_profile_type', 'Profil inconnu');
    }

    this.logger.log(`Sessions révoquées pour ${type} ${userId}`);
    return { revoked: true };
  }

  /**
   * @param tokenVersion valeur courante du compte, embarquée dans le jeton.
   *   Le garde la compare à chaque requête : incrémenter la colonne invalide
   *   instantanément tous les jetons déjà émis (revue M12).
   */
  private generateToken(
    userId: string,
    email: string,
    type: 'merchant' | 'fleet' | 'transporteur',
    tokenVersion = 0,
  ) {
    // Must be a number (seconds), not a bare numeric string: jsonwebtoken's `ms`
    // dependency interprets a unitless string like "86400" as milliseconds (~86s),
    // not seconds, silently producing tokens that expire almost immediately.
    const expiresIn = jwtExpirationSeconds(this.configService);
    return this.jwtService.sign(
      {
        sub: userId,
        email,
        type,
        tv: tokenVersion,
      },
      { expiresIn },
    );
  }
}
