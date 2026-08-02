import { FleetbaseApiClient } from './fleetbase-api.client';

/**
 * Le découpage d'une liste par Fleetbase plutôt qu'en mémoire.
 *
 * ── Ce que ces cas protègent ────────────────────────────────────────────────
 *
 * `getOrderPage()` remplace un parcours de cinquante pages par une requête.
 * L'économie est réelle ; le risque l'est aussi, et il est d'un genre
 * particulier : **une pagination fausse ne lève rien**. Elle rend une liste
 * plus courte, ce qui ressemble à « il n'y a rien de plus ».
 *
 * ⚠️ Le cas qui compte n'est donc pas celui où tout va bien, c'est **`total`
 * absent**. Si on le remplaçait par `orders.length`, une page pleine
 * annoncerait « voilà tout » et l'appelant s'arrêterait sur un multiple de la
 * taille de page — sans erreur, sans journal, sans rien à constater. Ce cas est
 * vérifié en premier.
 */
describe('une page de commandes servie par Fleetbase', () => {
  const clientWith = (response: any) => {
    // On exécute la vraie méthode, sans instancier le module HTTP : c'est le
    // corps de `getOrderPage` qui est en cause, pas le transport.
    const client: any = Object.create(FleetbaseApiClient.prototype);
    client.logger = { warn: jest.fn(), error: jest.fn(), log: jest.fn() };
    client.getAllOrders = jest.fn().mockResolvedValue(response);
    // `any` volontaire : `logger` est privé sur la classe, et l'intersecter le
    // réduirait à `never`. On inspecte ici un doublure, pas le vrai client.
    return client as any;
  };

  const page = (client: any, p = 1, limit = 25, filters: any = {}) =>
    FleetbaseApiClient.prototype.getOrderPage.call(client, p, limit, filters);

  it('rend le total servi par Fleetbase', async () => {
    const client = clientWith({ orders: [{ uuid: 'a' }, { uuid: 'b' }], meta: { total: 422 } });
    await expect(page(client)).resolves.toEqual({
      orders: [{ uuid: 'a' }, { uuid: 'b' }],
      total: 422,
    });
  });

  it('rend `null` plutôt que d’inventer un total, et le dit', async () => {
    // Le défaut que ce test existe pour empêcher : `orders.length` vaudrait 25
    // sur une page pleine, donc « fin de liste » au milieu de la liste.
    const orders = Array.from({ length: 25 }, (_, i) => ({ uuid: `o${i}` }));
    const client = clientWith({ orders });

    const result = await page(client);
    expect(result.total).toBeNull();
    expect(result.orders).toHaveLength(25);
    // Une absence silencieuse serait indétectable en exploitation.
    expect(client.logger.warn).toHaveBeenCalled();
  });

  it('refuse un total qui n’est pas un nombre exploitable', async () => {
    for (const bad of ['422', null, undefined, NaN, Infinity, {}]) {
      const client = clientWith({ orders: [], meta: { total: bad } });
      expect((await page(client)).total).toBeNull();
    }
  });

  it('accepte un total de zéro — vide n’est pas inconnu', async () => {
    // Témoin du cas précédent : `0` est falsy, et le confondre avec une absence
    // ferait repartir l'appelant sur un parcours complet pour rien.
    const client = clientWith({ orders: [], meta: { total: 0 } });
    expect((await page(client)).total).toBe(0);
  });

  it('relaie page, taille et filtres tels quels', async () => {
    const client = clientWith({ orders: [], meta: { total: 0 } });
    await page(client, 3, 25, { facilitator: 'v-1', status: 'created' });
    expect(client.getAllOrders).toHaveBeenCalledWith(3, 25, {
      facilitator: 'v-1',
      status: 'created',
    });
  });

  it('tolère les enveloppes de collection de Fleetbase', async () => {
    // Le même serveur répond tantôt `orders`, tantôt `data` (journal §2.4).
    for (const body of [
      { orders: [{ uuid: 'a' }], meta: { total: 1 } },
      { data: [{ uuid: 'a' }], meta: { total: 1 } },
    ]) {
      const result = await page(clientWith(body));
      expect(result.orders).toEqual([{ uuid: 'a' }]);
      expect(result.total).toBe(1);
    }
  });
});
