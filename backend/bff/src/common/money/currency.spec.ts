import { readOrderCustomFields } from '../../fleetbase/order-custom-fields';
import { projectOrderForMerchant } from '../projections/order.projection';
import { DEFAULT_PLATFORM_CURRENCY, platformCurrency } from './currency';

/**
 * La devise servie ne dépend plus de la couche qui répond.
 *
 * ── Ce que ces cas reproduisent ─────────────────────────────────────────────
 *
 * Le défaut du 02/08/2026 : « 777 USD » pour le prix, « À encaisser : 2727 DZD »
 * deux lignes plus bas, sur la même course. Cause exacte — `Order` a **déjà**
 * une colonne `currency` (défaut `USD`) et notre champ personnalisé porte le
 * même nom ; sur la liste, où les valeurs des champs personnalisés sont
 * absentes, le repli à plat lisait celle de Fleetbase et l'emportait sur la
 * nôtre.
 *
 * ⚠️ **Chaque cas porte son témoin.** Un test qui vérifie « la devise vaut DZD »
 * passerait sur du code qui écrit `DZD` en dur partout — y compris sur le code
 * fautif, puisque le registre de caisse, lui, disait déjà `DZD`. C'est la
 * commande **servie avec `currency: 'USD'` par Fleetbase** qui prouve quelque
 * chose : sans la correction, elle ressort en USD.
 */
describe('la devise de la plateforme', () => {
  const asFleetbaseListRow = (over: Record<string, any> = {}) => ({
    uuid: 'o-1',
    status: 'created',
    // La ressource d'index : `meta` réduite à son drapeau, aucune valeur de
    // champ personnalisé, et la colonne `currency` de Fleetbase à découvert.
    meta: { _index_resource: true },
    currency: 'USD',
    ...over,
  });

  describe('platformCurrency', () => {
    it('retombe sur le DZD quand rien n’est configuré', () => {
      expect(platformCurrency(undefined)).toBe('DZD');
      expect(platformCurrency(null)).toBe('DZD');
      expect(platformCurrency('')).toBe('DZD');
      expect(platformCurrency('   ')).toBe('DZD');
      expect(DEFAULT_PLATFORM_CURRENCY).toBe('DZD');
    });

    it('respecte une devise configurée — la valeur est un réglage, pas une constante', () => {
      expect(platformCurrency('EUR')).toBe('EUR');
      expect(platformCurrency(' EUR ')).toBe('EUR');
    });
  });

  describe('le repli à plat', () => {
    it('REFUSE la devise que Fleetbase sert lui-même', () => {
      // Le cœur du défaut : sans la garde, cette ligne rendait { currency: 'USD' }.
      expect(readOrderCustomFields(asFleetbaseListRow())).toEqual({});
    });

    it('lit toujours à plat ce que Fleetbase ne nomme pas', () => {
      // Témoin : la garde doit être ciblée, pas désactiver le repli entier.
      const read = readOrderCustomFields(asFleetbaseListRow({ price: '650' }));
      expect(read.price).toBe(650);
      expect(read.currency).toBeUndefined();
    });

    it('garde la vraie valeur quand elle est là, même si Fleetbase en sert une autre', () => {
      const read = readOrderCustomFields(
        asFleetbaseListRow({
          custom_field_values: [{ custom_field: { name: 'currency' }, value: 'DZD' }],
        }),
      );
      expect(read.currency).toBe('DZD');
    });
  });

  describe('la projection', () => {
    it('sert la devise de la plateforme là où Fleetbase servait la sienne', () => {
      const projected = projectOrderForMerchant({
        ...asFleetbaseListRow(),
        meta: { price: 777, currency: 'USD', cod_amount: 2727, cod_currency: 'DZD' },
      });
      // Le défaut exact, dans les deux sens : une seule devise sur la course.
      expect(projected.meta.currency).toBe('DZD');
      expect(projected.meta.cod_currency).toBe('DZD');
      expect(projected.meta.currency).toBe(projected.meta.cod_currency);
    });

    it('ne touche PAS aux montants — le libellé change, la somme jamais', () => {
      const projected = projectOrderForMerchant({
        ...asFleetbaseListRow(),
        meta: { price: 777, currency: 'USD', cod_amount: 2727 },
      });
      expect(projected.meta.price).toBe(777);
      expect(projected.meta.cod_amount).toBe(2727);
    });

    it('n’invente pas de devise sur une course sans montant', () => {
      // Règle 10 : « DZD » seul décrirait une somme qui n'existe pas, et
      // effacerait l'information que le prix manque.
      const projected = projectOrderForMerchant({
        ...asFleetbaseListRow(),
        meta: { instructions: 'sonner au 3e' },
      });
      expect(projected.meta?.currency).toBeUndefined();
      expect(projected.meta?.cod_currency).toBeUndefined();
    });

    it('donne la devise du montant à encaisser sans exiger un prix', () => {
      const projected = projectOrderForMerchant({
        ...asFleetbaseListRow(),
        meta: { cod_amount: 2727 },
      });
      expect(projected.meta.cod_currency).toBe('DZD');
      expect(projected.meta.currency).toBeUndefined();
    });
  });
});
