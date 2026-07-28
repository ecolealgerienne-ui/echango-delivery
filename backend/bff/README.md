# Echango BFF (Backend For Frontend)

Backend For Frontend service for Echango Delivery platform. Provides API endpoints for merchant and fleet manager interfaces.

## Tech Stack

- **Runtime**: Node.js 20+
- **Framework**: NestJS 11
- **Language**: TypeScript 5.5
- **Database**: PostgreSQL 16 (via Prisma ORM)
- **Auth**: JWT (Bearer tokens)
- **Cache**: Redis (optional, for sessions)
- **Containerization**: Docker

## Setup

### Prerequisites

- Node.js 20+
- PostgreSQL 16+
- Docker & Docker Compose (for containerized setup)

### Local Development (Without Docker)

```bash
# 1. Install dependencies
npm install

# 2. Set up environment
cp .env.example .env
# Edit .env with your Fleetbase API key, JWT secret, etc.

# 3. Generate Prisma client
npm run prisma:generate

# 4. Run database migrations
npm run prisma:migrate

# 5. Start development server
npm run start:dev
```

### Local Development (With Docker)

```bash
# 1. Set environment variables
export FLEETBASE_API_KEY=your_api_key
export JWT_SECRET=your_jwt_secret

# 2. Start all services
docker-compose up

# 3. Run migrations (in container)
docker exec echango_bff_app npm run prisma:migrate
```

## API Endpoints

### Auth (Public)
- `POST /auth/merchant/register` - Register merchant account
- `POST /auth/merchant/login` - Login merchant
- `POST /auth/flotte/register` - Register fleet manager account
- `POST /auth/flotte/login` - Login fleet manager
- `POST /auth/transporteur/register` - Link an Echango account to an already-provisioned Fleetbase Driver (manual provisioning - see docs/specs_app_transporteur.md §2.1)
- `POST /auth/transporteur/login` - Login driver
- `POST /auth/verify` - Verify current token

### Auth (Requires Auth)
- `POST /auth/device-token` - Register push token (merchant)
- `POST /auth/transporteur/device-token` - Register push token (driver) - mirrored to a Fleetbase `UserDevice` record so native FCM/APN dispatch can reach it, see `docs/journal_implementation_bff.md`

### Merchant (`/commercant/*`, Requires Auth)
- `POST /commercant/commandes` - Create order
- `GET /commercant/commandes` - List orders
- `GET /commercant/commandes/:id` - Get order detail
- `POST /commercant/commandes/:id/annuler` - Cancel order
- `GET /commercant/commandes/:id/suivi` - Track order (secure)
- `POST /commercant/device-token` - Register push notification token
- `GET /commercant/adresses` - Get saved addresses
- `POST /commercant/adresses` - Save address

### Fleet (`/flotte/*`, Requires Auth)
- `GET /flotte/commandes` - List fleet orders
- `GET /flotte/commandes/:id` - Get order detail
- `GET /flotte/drivers` - List drivers
- `POST /flotte/drivers` - Add driver to fleet
- `GET /flotte/drivers/positions` - Get all driver positions
- `POST /flotte/commandes/:id/assigner` - Assign driver to order

## Database Schema

Key models in `prisma/schema.prisma`:
- **MerchantAccount** - Echango merchant user (not Fleetbase User)
- **FleetAccount** - Fleet manager account
- **DriverAccount** - Echango driver ("transporteur") account, linked to an already-provisioned Fleetbase Driver
- **DeviceToken** - FCM tokens for push notifications (merchant)
- **DriverDeviceToken** - FCM tokens for push notifications (driver), mirrored to Fleetbase `UserDevice`
- **Order** - Order cache from Fleetbase
- **Commission** - Commission ledger
- **AuditLog** - Audit trail for security

## Architecture

```
src/
├── auth/              # Registration, login, JWT tokens
├── commercant/        # Merchant API endpoints
├── flotte/            # Fleet manager API endpoints
├── fleetbase/         # Fleetbase API client
├── database/          # Prisma service
├── common/            # Guards, filters, decorators
└── app.module.ts      # Root module
```

## Key Design Decisions

1. **Two Auth Strategies**: 
   - Merchants use Fleetbase `customer-portal-api` (Sanctum token)
   - Fleet managers use BFF service account (no individual Fleetbase user)

2. **Bearer-Only**: No cookies, all auth via JWT Bearer tokens (mobile-friendly)

3. **Data Isolation**: BFF stores Echango-only data (accounts, commissions). Fleetbase remains source of truth for orders/drivers.

4. **Anti-IDOR**: Every endpoint validates resource ownership before returning data.

## Deployment

### Docker Build & Run

```bash
docker build -t echango-bff:latest .
docker run -p 3001:3001 \
  -e DATABASE_URL=postgresql://... \
  -e FLEETBASE_API_KEY=... \
  -e JWT_SECRET=... \
  echango-bff:latest
```

### Environment Variables

See `.env.example` for all required variables.

## Testing

```bash
# Run unit tests
npm test

# Watch mode
npm test:watch

# Coverage
npm test:cov

# E2E tests
npm run test:e2e
```

## Linting & Formatting

```bash
# Lint
npm run lint

# Format
npm run format
```

## Database Migrations

```bash
# Create new migration
npm run prisma:migrate -- --name <migration_name>

# Seed database (if seed.ts exists)
npm run prisma:seed
```

## Support

See `docs/specs_bff.md` for full specification.
See `docs/decisions_bff_mvp.md` for MVP decisions.
