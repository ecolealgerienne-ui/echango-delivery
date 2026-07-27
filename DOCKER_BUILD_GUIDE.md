# BFF Docker Build & Test Guide

This guide walks you through building and running the Echango Delivery BFF (Backend For Frontend) in Docker in your WSL environment.

## Prerequisites

- Docker & Docker Compose installed in WSL
- Fleetbase running locally on `http://localhost:8000` (see `CLAUDE.md` for setup)
- Valid `FLEETBASE_API_KEY` from your Fleetbase instance

## Quick Start

### 1. Navigate to the BFF directory

```bash
cd backend/bff
```

### 2. Create `.env` file from template

```bash
cp .env.example .env
```

Update these values in `.env`:

```env
# Get from Fleetbase console (Settings → API Keys)
FLEETBASE_API_KEY=your_actual_key_here
FLEETBASE_ORGANIZATION_UUID=your_org_uuid_here

# Change for production
JWT_SECRET=dev-secret-key

# Firebase (optional for development - set to dummy values)
FIREBASE_PROJECT_ID=dev-project
FIREBASE_PRIVATE_KEY={"type":"service_account"}
FIREBASE_CLIENT_EMAIL=firebase@example.com

# Email (optional - Mailtrap for dev)
MAIL_HOST=smtp.mailtrap.io
MAIL_PORT=465
MAIL_USER=dev
MAIL_PASSWORD=dev
```

### 3. Build Docker images

```bash
docker-compose build --no-cache
```

This will:
- Install Node.js dependencies (npm install)
- Generate Prisma client
- Compile TypeScript to JavaScript
- Create runtime image with production dependencies

**Expected output**: Images built successfully with no TypeScript errors.

### 4. Start services

```bash
docker-compose up -d
```

This starts:
- PostgreSQL (port 5432)
- Redis (port 6379)
- BFF app (port 3001)

### 5. Run database migrations

```bash
docker exec echango_bff_app npm run prisma:migrate
```

This creates tables in PostgreSQL based on `prisma/schema.prisma`.

### 6. Verify BFF is running

```bash
curl http://localhost:3001/health
```

Should return a 200 response.

## Testing Week 2 Endpoints

### Merchant Registration

```bash
curl -X POST http://localhost:3001/auth/merchant/register \
  -H "Content-Type: application/json" \
  -d '{
    "email": "merchant@example.com",
    "password": "SecurePass123!",
    "businessName": "Test Bakery",
    "firstName": "Ahmed",
    "lastName": "Smith"
  }'
```

Expected response:
```json
{
  "id": "...",
  "email": "merchant@example.com",
  "token": "eyJhbGc..."
}
```

### Merchant Login

```bash
curl -X POST http://localhost:3001/auth/merchant/login \
  -H "Content-Type: application/json" \
  -d '{
    "email": "merchant@example.com",
    "password": "SecurePass123!"
  }'
```

### Register Device Token (requires auth)

```bash
TOKEN="eyJhbGc..."  # from login response

curl -X POST http://localhost:3001/auth/device-token \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "token": "fcm_token_here",
    "platform": "android"
  }'
```

### Get Merchant Orders

```bash
TOKEN="eyJhbGc..."

curl -X GET "http://localhost:3001/commercant/commandes?page=1&limit=10" \
  -H "Authorization: Bearer $TOKEN"
```

Expected response:
```json
{
  "data": [],
  "pagination": {
    "page": 1,
    "limit": 10,
    "total": 0,
    "pages": 0
  }
}
```

### Create Order

```bash
TOKEN="eyJhbGc..."

curl -X POST http://localhost:3001/commercant/commandes \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "pickupLocationName": "Test Bakery",
    "pickupLatitude": 36.737232,
    "pickupLongitude": 3.058727,
    "pickupContactName": "Ahmed",
    "pickupContactPhone": "+213600000000",
    "dropoffLocationName": "Customer Home",
    "dropoffLatitude": 36.747232,
    "dropoffLongitude": 3.068727,
    "dropoffContactName": "Customer",
    "dropoffContactPhone": "+213611111111",
    "items": [
      {
        "name": "Baguette",
        "quantity": 2,
        "weight": "500g"
      }
    ],
    "deliveryInstructions": "Ring doorbell twice"
  }'
```

This calls Fleetbase to create a real order (ensure Fleetbase is running).

### Get Order Detail

```bash
TOKEN="eyJhbGc..."
ORDER_ID="order_id_from_create_response"

curl -X GET "http://localhost:3001/commercant/commandes/$ORDER_ID" \
  -H "Authorization: Bearer $TOKEN"
```

### Save Address

```bash
TOKEN="eyJhbGc..."

curl -X POST http://localhost:3001/commercant/adresses \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "label": "Main Store",
    "name": "Test Bakery",
    "address": "123 Main St, Algiers",
    "latitude": 36.737232,
    "longitude": 3.058727,
    "contactName": "Ahmed",
    "contactPhone": "+213600000000"
  }'
```

### Get Addresses

```bash
TOKEN="eyJhbGc..."

curl -X GET http://localhost:3001/commercant/adresses \
  -H "Authorization: Bearer $TOKEN"
```

## Troubleshooting

### Build Fails with TypeScript Errors

```
error TS1219: Experimental decorators are not permitted in this environment
```

**Solution**: tsconfig.json has been updated with `experimentalDecorators: true` and `emitDecoratorMetadata: true`. Rebuild with:

```bash
docker-compose build --no-cache
```

### Database Connection Error

```
Error: connect ECONNREFUSED 127.0.0.1:5432
```

**Solution**: Ensure PostgreSQL service is healthy:

```bash
docker-compose ps
# postgres should show "healthy"

docker-compose logs postgres
# Check for startup errors
```

### Fleetbase API Errors

```
error AxiosError: 401 Unauthorized
```

**Solution**: Verify your credentials:

```bash
# Check your Fleetbase API key is correct
grep FLEETBASE_API_KEY .env

# Test Fleetbase is running
curl http://localhost:8000/api/v1/health

# Check BFF logs
docker-compose logs bff | tail -20
```

### Port Already in Use

```
Error response from daemon: Ports are not available
```

**Solution**: Check what's using the ports:

```bash
# Kill existing containers
docker-compose down -v

# Or use different ports by modifying docker-compose.yml
```

## Development Workflow

### View logs

```bash
# All services
docker-compose logs -f

# Just BFF
docker-compose logs -f bff

# Just database
docker-compose logs -f postgres
```

### Run commands in container

```bash
# Prisma commands
docker exec echango_bff_app npm run prisma:generate
docker exec echango_bff_app npm run prisma:migrate

# Database shell
docker exec -it echango_bff_postgres psql -U bff_user -d echango_bff
```

### Live reload (development mode)

The BFF is configured to run `npm run start:dev` which watches for file changes:

```bash
docker-compose up -d bff
# Edit a .ts file in src/
# BFF automatically recompiles and restarts
```

### Stop services

```bash
docker-compose down
# With volume cleanup
docker-compose down -v
```

## Week 2 Implementation Status

✅ **Completed**:
- Merchant authentication (register/login)
- JWT token validation & Bearer auth
- Device token registration (FCM setup foundation)
- Merchant orders list with pagination & filtering
- Order detail with anti-IDOR checks
- Order creation (Fleetbase integration)
- Order cancellation with status validation
- Order tracking with secure access
- Address CRUD operations
- Flotte module scaffolding

✅ **Infrastructure**:
- PostgreSQL for data persistence
- Redis for caching/sessions
- Docker multi-stage build
- Health checks & signal handling
- Global exception & logging handlers
- Validation & CORS

🚀 **Next Steps** (Week 3+):
- Flotte manager endpoints (list/detail orders, drivers, assignments)
- Real-time notifications via Firebase Cloud Messaging
- Commission calculation engine
- Audit logging
- Unit & E2E tests

## Notes

- All endpoints require Bearer JWT token authentication (except /auth/merchant/register and /auth/merchant/login)
- Merchant data is isolated in BFF database; Fleetbase holds logistics data
- Fleetbase connectivity is required for order operations
- CORS is configured for development; update `main.ts` for production URLs

For detailed architecture, see `docs/specs_bff.md` in the project root.
