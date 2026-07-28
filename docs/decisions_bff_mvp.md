# BFF MVP Decisions — Locked In (27 juillet 2026, v2)

Decisions made to unblock BFF development. These override/clarify ambiguities in `specs_bff.md`.

## Locked Decisions

| Question | Decision | Rationale |
|----------|----------|-----------|
| Merchant provisioning | **Self-service** | BFF endpoint for merchant registration. Handles Fleetbase account creation. |
| Order tracking | **Secure BFF endpoint** (`/commercant/commandes/{id}/suivi`) | Custom auth, not Fleetbase public URL (mt_rand enumerable risk). |
| Service account(s) | **Single key** | One API credential, full Organization access. Test IAM scoping later if security posture demands. |
| Address source | **`address-book`** | Vendor-scoped, aligns with data isolation. |
| Driver assignment acknowledgment | **Manual re-assign** | No auto-timeout for MVP. Fleet manager reassigns if driver doesn't respond. |
| Multi-role account model | **Separate accounts (MVP)** | One Echango account = one persona (merchant OR fleet). Unify later if a real Vendor wants both roles. Design allows extension. |
| Commission calculation | **BFF calculates** | Single source of truth. Model is **hybrid (TBD)** — BFF must support pluggable tarification logic, not hardcode one formula. |

## Implications

### Auth & Provisioning
- `POST /auth/register` — merchant self-service. BFF orchestrates: create Echango account, create Fleetbase Customer + User, Sanctum token.
- `POST /auth/login` — email + password (merchants), service login endpoint (fleet manager, manual provisioning only for now).
- Token management: Bearer Echango token, issued by BFF. Fleetbase credentials (Sanctum, service key) never exposed to clients.

### API Surface (MVP Locked)

**Merchant** (`/commercant/*`):
- `POST /auth/register`, `POST /auth/login` — self-service flow
- `POST /commandes` — place order (with pré-remplissage pickup/dropoff from address-book)
- `GET /commandes`, `GET /commandes/{id}` — list + detail (with failure reason if applicable)
- `POST /commandes/{id}/annuler` — cancellation
- `POST /device-token` — FCM token for push notifications
- `GET /adresses`, `POST /adresses` — address-book (Fleetbase `address-book`)
- `GET /commandes/{id}/suivi` — **secure tracking endpoint**, auth-required (not public URL)

**Fleet** (`/flotte/*`):
- Service login (manual provisioning only, TBD auth method)
- `GET /commandes`, `GET /commandes/{id}` — fleet-scoped orders
- `GET /drivers` — drivers + availability status
- `GET /drivers/positions` — bulk position fetch
- `POST /drivers` — onboard driver to fleet
- `POST /commandes/{id}/assigner` — assign driver (manual re-attempt if no response)

### Tarification (Pluggable)
- BFF must support **hybrid commission model** (percentage + fixed + distance, exact formula TBD).
- Must be **independent of Fleetbase Ledger** (do not rely on `PurchaseRate` for commission logic — that's for e-invoice from Fleetbase).
- Endpoint: `GET /commercant/commandes/{id}` response includes `commission_amount`, derived from **BFF tarification engine**, not Fleetbase.
- Commission calculation **deferred until tarification model finalized** (Phase 2 likely), but architecture must not block it.

## Open for Later (Phase 2+)

- Auto-timeout on driver assignment
- Unifying merchant + fleet roles
- Fleetbase Ledger integration (invoicing)
- Navigator integration (if revisited)
- Rate limiting, advanced audit logging
