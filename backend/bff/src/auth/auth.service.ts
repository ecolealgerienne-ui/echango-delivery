import { Injectable, BadRequestException, UnauthorizedException, Logger, ConflictException } from '@nestjs/common';
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
  ) {}

  /**
   * Register a new merchant
   * Creates Echango account + Fleetbase Vendor + Customer
   */
  async registerMerchant(dto: MerchantRegisterDto) {
    // Check if email already exists
    const existing = await this.prisma.merchantAccount.findUnique({
      where: { email: dto.email },
    });

    if (existing) {
      throw new ConflictException('Email already registered');
    }

    // Retenu pour la compensation ci-dessous : une inscription qui échoue
    // après la création du Vendor laissait un enregistrement orphelin dans
    // Fleetbase, invisible du BFF et impossible à réutiliser — le `@unique` sur
    // `fleetbaseVendorUuid` n'y voit rien, et une seconde tentative avec le
    // même email recréait un second Vendor (revue archi #11).
    let createdVendorUuid: string | null = null;

    try {
      // 1. Create Vendor in Fleetbase
      this.logger.log(`Creating Vendor in Fleetbase for ${dto.businessName}`);
      const vendorResponse = await this.fleetbaseClient.createVendor(
        dto.businessName,
        dto.email,
        dto.businessPhone,
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
          firstName: dto.firstName,
          lastName: dto.lastName,
          businessName: dto.businessName,
          phone: dto.phone,
          businessPhone: dto.businessPhone,
          fleetbaseVendorUuid: vendorUuid,
          fleetbaseCustomerUuid: customerUuid,
          emailVerified: true, // TODO: Email verification in v2
        },
      });

      this.logger.log(`Merchant registered: ${merchant.id}`);

      // 4. Generate JWT token
      const token = this.generateToken(merchant.id, merchant.email, 'merchant', merchant.tokenVersion);

      return {
        token,
        user: {
          id: merchant.id,
          email: merchant.email,
          businessName: merchant.businessName,
        },
      };
    } catch (error) {
      this.logger.error(`Merchant registration failed: ${error.message}`, error);
      await this.rollbackVendor(createdVendorUuid);

      const detail = error.response?.data ? JSON.stringify(error.response.data) : error.message;
      throw new BadRequestException(
        this.configService.get('NODE_ENV') === 'development'
          ? `Failed to register merchant: ${detail}`
          : 'Failed to register merchant',
      );
    }
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
      throw new UnauthorizedException(INVALID_CREDENTIALS);
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
      throw new UnauthorizedException(INVALID_CREDENTIALS);
    }

    const passwordMatches = await bcrypt.compare(dto.password, merchant.password);

    if (!passwordMatches) {
      throw new UnauthorizedException(INVALID_CREDENTIALS);
    }

    if (!merchant.emailVerified) {
      throw new UnauthorizedException(INVALID_CREDENTIALS);
    }

    if (!merchant.active) {
      throw new UnauthorizedException(INVALID_CREDENTIALS);
    }

    // Update last login
    await this.prisma.merchantAccount.update({
      where: { id: merchant.id },
      data: { lastLoginAt: new Date() },
    });

    this.logger.log(`Merchant logged in: ${merchant.id}`);

    // Generate JWT token
    const token = this.generateToken(merchant.id, merchant.email, 'merchant', merchant.tokenVersion);

    return {
      token,
      user: {
        id: merchant.id,
        email: merchant.email,
        businessName: merchant.businessName,
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

    if (existing) {
      throw new ConflictException('Email already registered');
    }

    try {
      this.logger.log(`Creating Vendor in Fleetbase for fleet ${dto.businessName}`);
      const vendorResponse = await this.fleetbaseClient.createVendor(
        dto.businessName,
        dto.email,
        dto.businessPhone,
      );

      const vendorUuid = vendorResponse.vendor?.uuid || vendorResponse.vendor?.id;
      if (!vendorUuid) {
        throw new Error('Vendor UUID not returned from Fleetbase');
      }

      const hashedPassword = await bcrypt.hash(dto.password, 10);

      const fleet = await this.prisma.fleetAccount.create({
        data: {
          email: dto.email,
          password: hashedPassword,
          firstName: dto.firstName,
          lastName: dto.lastName,
          businessName: dto.businessName,
          phone: dto.phone,
          businessPhone: dto.businessPhone,
          fleetbaseVendorUuid: vendorUuid,
        },
      });

      this.logger.log(`Fleet account registered: ${fleet.id}`);

      const token = this.generateToken(fleet.id, fleet.email, 'fleet', fleet.tokenVersion);

      return {
        token,
        user: {
          id: fleet.id,
          email: fleet.email,
          businessName: fleet.businessName,
        },
      };
    } catch (error) {
      this.logger.error(`Fleet registration failed: ${error.message}`, error);
      const detail = error.response?.data ? JSON.stringify(error.response.data) : error.message;
      throw new BadRequestException(
        this.configService.get('NODE_ENV') === 'development'
          ? `Failed to register fleet account: ${detail}`
          : 'Failed to register fleet account',
      );
    }
  }

  /**
   * Login fleet manager with email/password
   */
  async loginFleet(dto: FleetLoginDto) {
    const fleet = await this.prisma.fleetAccount.findUnique({
      where: { email: dto.email },
    });

    if (!fleet) {
      throw new UnauthorizedException(INVALID_CREDENTIALS);
    }

    const passwordMatches = await bcrypt.compare(dto.password, fleet.password);

    if (!passwordMatches) {
      throw new UnauthorizedException(INVALID_CREDENTIALS);
    }

    if (!fleet.active) {
      throw new UnauthorizedException(INVALID_CREDENTIALS);
    }

    await this.prisma.fleetAccount.update({
      where: { id: fleet.id },
      data: { lastLoginAt: new Date() },
    });

    this.logger.log(`Fleet manager logged in: ${fleet.id}`);

    const token = this.generateToken(fleet.id, fleet.email, 'fleet', fleet.tokenVersion);

    return {
      token,
      user: {
        id: fleet.id,
        email: fleet.email,
        businessName: fleet.businessName,
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
      throw new BadRequestException(
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
  async createDriverInvitation(fleetbaseDriverUuid: string, email?: string, validForDays = 7) {
    const token = randomBytes(32).toString('base64url');
    const expiresAt = new Date(Date.now() + validForDays * 24 * 60 * 60 * 1000);

    try {
      const existing = await this.prisma.driverAccount.findUnique({
        where: { fleetbaseDriverUuid },
      });
      if (existing) {
        throw new ConflictException('This driver already has an Echango account');
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
      throw new BadRequestException(
        this.configService.get('NODE_ENV') === 'development'
          ? `Émission d'invitation impossible : ${error.message}`
          : 'Could not issue driver invitation',
      );
    }

    this.logger.log(`Driver invitation issued for ${fleetbaseDriverUuid}`);

    return { invitationToken: token, expiresAt };
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
        throw new ConflictException('Email already registered');
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
        throw new BadRequestException('Invitation invalide ou expirée');
      }

      // Une invitation nominative ne vaut que pour l'email visé.
      if (invitation.email && invitation.email.toLowerCase() !== dto.email.toLowerCase()) {
        throw new BadRequestException('Invitation invalide ou expirée');
      }

      const existingUuid = await this.prisma.driverAccount.findUnique({
        where: { fleetbaseDriverUuid: invitation.fleetbaseDriverUuid },
      });

      if (existingUuid) {
        throw new ConflictException('This driver is already linked to an account');
      }

      // Lecture unitaire (journal §24). Elle compare l'uuid renvoyé à celui
      // demandé, ce qui compte particulièrement ici : ce que cet appel ramène
      // détermine à quel transporteur le nouveau compte sera rattaché.
      const fleetbaseDriver = await this.fleetbaseClient.getDriverByUuid(
        invitation.fleetbaseDriverUuid,
      );

      if (!fleetbaseDriver) {
        throw new BadRequestException('Unknown Fleetbase driver UUID - ask an operator to verify provisioning');
      }

      const hashedPassword = await bcrypt.hash(dto.password, 10);

      const driver = await this.prisma.driverAccount.create({
        data: {
          email: dto.email,
          password: hashedPassword,
          firstName: dto.firstName,
          lastName: dto.lastName,
          phone: dto.phone,
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
        user: {
          id: driver.id,
          email: driver.email,
          firstName: driver.firstName,
          lastName: driver.lastName,
        },
      };
    } catch (error) {
      if (error instanceof BadRequestException || error instanceof ConflictException) {
        throw error;
      }
      this.logger.error(`Driver registration failed: ${error.message}`, error);

      this.rethrowIfPrismaSetupIssue(error, 'driverAccount');

      const detail = error.response?.data ? JSON.stringify(error.response.data) : error.message;
      throw new BadRequestException(
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
      throw new UnauthorizedException(INVALID_CREDENTIALS);
    }

    const passwordMatches = await bcrypt.compare(dto.password, driver.password);

    if (!passwordMatches) {
      throw new UnauthorizedException(INVALID_CREDENTIALS);
    }

    if (!driver.active) {
      throw new UnauthorizedException(INVALID_CREDENTIALS);
    }

    await this.prisma.driverAccount.update({
      where: { id: driver.id },
      data: { lastLoginAt: new Date() },
    });

    this.logger.log(`Driver logged in: ${driver.id}`);

    const token = this.generateToken(driver.id, driver.email, 'transporteur', driver.tokenVersion);

    return {
      token,
      user: {
        id: driver.id,
        email: driver.email,
        firstName: driver.firstName,
        lastName: driver.lastName,
      },
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
      throw new BadRequestException('Driver not found');
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
      throw new BadRequestException('Merchant not found');
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

  /**
   * Verify JWT token and return payload
   */
  verifyToken(token: string) {
    try {
      return this.jwtService.verify(token);
    } catch (error) {
      throw new UnauthorizedException('Invalid or expired token');
    }
  }

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
        throw new BadRequestException('Profil inconnu');
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
    const expiresIn = parseInt(this.configService.get('JWT_EXPIRATION') || '86400', 10);
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
