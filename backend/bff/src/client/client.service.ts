import { Injectable, Logger } from '@nestjs/common';
import * as crypto from 'crypto';
import { PrismaService } from '../database/prisma.service';
import { badRequest, notFound, conflict, forbidden } from '../common/errors/http-errors';
import { normalizePhone } from '../common/phone/phone';
import { ResourceLockService } from '../common/concurrency/resource-lock.service';

/**
 * 10 minutes — décision produit
 * (`docs/specs_localisation_client_et_optimisation_parcours.md` §1.2).
 */
const LINK_TTL_MINUTES = 10;

export type LinkState = 'pending' | 'expired' | 'used' | 'not_found';

/**
 * Fiche client géolocalisée, portée plateforme
 * (`docs/specs_localisation_client_et_optimisation_parcours.md` §1).
 *
 * ⚠️ **Aucun contrôle d'appartenance de ressource au-delà de l'authentification
 * commerçant** : la fiche n'appartient à personne en particulier — c'est le
 * choix produit assumé en §1.7 (un commerçant B peut lire une position
 * partagée en réponse au lien d'un commerçant A). Seule l'inscription du
 * commerçant est vérifiée (`getMerchantWithValidation`, même garde que
 * `CommerçantService`).
 */
@Injectable()
export class ClientService {
  private readonly logger = new Logger(ClientService.name);

  constructor(
    private prisma: PrismaService,
    private lock: ResourceLockService,
  ) {}

  private async getMerchantWithValidation(merchantId: string) {
    const merchant = await this.prisma.merchantAccount.findUnique({ where: { id: merchantId } });
    if (!merchant) notFound('merchant.not_found', 'Merchant not found');
    if (!merchant.active) forbidden('merchant.inactive', 'Merchant account is inactive');
    return merchant;
  }

  private requirePhone(raw: string): string {
    const phone = normalizePhone(raw);
    if (!phone) badRequest('client.phone_invalid', 'Numéro de téléphone invalide');
    return phone as string;
  }

  // ── Côté commerçant ────────────────────────────────────────────────────

  async getClient(merchantId: string, rawPhone: string) {
    await this.getMerchantWithValidation(merchantId);
    const phone = this.requirePhone(rawPhone);
    const client = await this.prisma.client.findUnique({ where: { phone } });
    if (!client) return { found: false as const };

    return {
      found: true as const,
      name: client.name,
      addressCity: client.addressCity,
      addressProvince: client.addressProvince,
      addressNeighborhood: client.addressNeighborhood,
      latitude: client.latitude,
      longitude: client.longitude,
      updatedAt: client.updatedAt,
      // Absence des trois champs = rien en attente (§1.3) — jamais un objet
      // vide qui se lirait comme « une proposition à coordonnées nulles ».
      pending:
        client.pendingLatitude != null && client.pendingLongitude != null
          ? {
              latitude: client.pendingLatitude,
              longitude: client.pendingLongitude,
              submittedAt: client.pendingSubmittedAt,
            }
          : null,
    };
  }

  async generateLink(merchantId: string, rawPhone: string) {
    await this.getMerchantWithValidation(merchantId);
    const phone = this.requirePhone(rawPhone);

    // Opaque et non devinable : jamais le numéro en clair dans une URL
    // partagée sur un canal que la plateforme ne contrôle pas (SMS/WhatsApp).
    const token = crypto.randomBytes(32).toString('base64url');
    const expiresAt = new Date(Date.now() + LINK_TTL_MINUTES * 60_000);

    try {
      await this.prisma.clientLocationLink.create({
        data: { token, merchantId, clientPhone: phone, expiresAt },
      });
    } catch (error: any) {
      this.logger.error(
        `Génération du lien de localisation échouée pour ${phone} : ${error.message}`,
      );
      badRequest('client.link_generate_failed', 'Génération du lien impossible');
    }

    const base = (process.env.PUBLIC_URL || 'http://localhost:3001').replace(/\/+$/, '');
    return { url: `${base}/public/localisation/${token}`, expiresAt };
  }

  /**
   * Applique la proposition en attente sur la fiche.
   *
   * Verrouillée sur `client:${phone}` et RELUE à l'intérieur du verrou
   * (`ResourceLockService` : le verrou seul ne suffit pas) — c'est le second
   * mécanisme de §1.4, dernier écrivain gagne entre deux confirmations
   * quasi simultanées.
   */
  async confirmPending(merchantId: string, rawPhone: string) {
    await this.getMerchantWithValidation(merchantId);
    const phone = this.requirePhone(rawPhone);

    return this.lock.withLock(`client:${phone}`, async () => {
      const client = await this.prisma.client.findUnique({ where: { phone } });
      if (!client || client.pendingLatitude == null || client.pendingLongitude == null) {
        conflict('client.no_pending_submission', 'Aucune position en attente pour ce numéro');
      }

      await this.prisma.client.update({
        where: { phone },
        data: {
          latitude: client!.pendingLatitude,
          longitude: client!.pendingLongitude,
          pendingLatitude: null,
          pendingLongitude: null,
          pendingSubmittedAt: null,
        },
      });
      return { confirmed: true };
    });
  }

  async rejectPending(merchantId: string, rawPhone: string) {
    await this.getMerchantWithValidation(merchantId);
    const phone = this.requirePhone(rawPhone);

    return this.lock.withLock(`client:${phone}`, async () => {
      const client = await this.prisma.client.findUnique({ where: { phone } });
      if (!client || client.pendingLatitude == null || client.pendingLongitude == null) {
        conflict('client.no_pending_submission', 'Aucune position en attente pour ce numéro');
      }

      await this.prisma.client.update({
        where: { phone },
        data: { pendingLatitude: null, pendingLongitude: null, pendingSubmittedAt: null },
      });
      return { rejected: true };
    });
  }

  // ── Public (page de localisation) ─────────────────────────────────────

  /**
   * Un seul point de calcul de l'état d'un lien, pour la route GET (rendu de
   * page) et la route POST (validation avant écriture) — règle 5 de
   * CLAUDE.md : les deux posent la même question, une divergence serait un
   * défaut, pas une variante.
   */
  async resolveLinkState(token: string): Promise<{ state: LinkState; link: any | null }> {
    const link = await this.prisma.clientLocationLink.findUnique({ where: { token } });
    if (!link) return { state: 'not_found', link: null };
    if (link.usedAt) return { state: 'used', link };
    if (link.expiresAt.getTime() <= Date.now()) return { state: 'expired', link };
    return { state: 'pending', link };
  }

  /**
   * Soumission de position par le client, depuis la page publique.
   *
   * `applied: true` — aucune position n'existait, écrite directement.
   * `applied: false` — une position existait déjà, la nouvelle est posée en
   * attente de confirmation (§1.4) : jamais un écrasement silencieux.
   */
  async submitLocation(token: string, lat: number, lng: number): Promise<{ applied: boolean }> {
    const { state, link } = await this.resolveLinkState(token);
    if (state === 'not_found') notFound('client.link_not_found', 'Lien introuvable');
    if (state === 'expired') conflict('client.link_expired', 'Ce lien a expiré');
    if (state === 'used') conflict('client.link_already_used', 'Ce lien a déjà été utilisé');

    const phone: string = link.clientPhone;

    return this.lock.withLock(`client:${phone}`, async () => {
      // Relecture À L'INTÉRIEUR du verrou : deux soumissions quasi
      // simultanées sur le même lien ne doivent pas passer toutes les deux
      // (le verrou seul ne suffit pas, cf. `ResourceLockService`).
      const fresh = await this.prisma.clientLocationLink.findUnique({ where: { token } });
      if (!fresh || fresh.usedAt) {
        conflict('client.link_already_used', 'Ce lien a déjà été utilisé');
      }

      await this.prisma.clientLocationLink.update({
        where: { token },
        data: { usedAt: new Date() },
      });

      const client = await this.prisma.client.findUnique({ where: { phone } });

      if (!client) {
        await this.prisma.client.create({ data: { phone, latitude: lat, longitude: lng } });
        return { applied: true };
      }

      if (client.latitude == null || client.longitude == null) {
        await this.prisma.client.update({
          where: { phone },
          data: { latitude: lat, longitude: lng },
        });
        return { applied: true };
      }

      await this.prisma.client.update({
        where: { phone },
        data: { pendingLatitude: lat, pendingLongitude: lng, pendingSubmittedAt: new Date() },
      });
      return { applied: false };
    });
  }
}
