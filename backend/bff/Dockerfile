# Development stage: full deps (incl. @nestjs/cli) + live reload via docker-compose volume mounts
FROM node:20-alpine AS development

WORKDIR /app

COPY package*.json ./
RUN npm install --legacy-peer-deps

COPY prisma ./prisma
RUN npx prisma generate

COPY . .

EXPOSE 3001

CMD ["npm", "run", "start:dev"]

# Build stage: compiles TypeScript for production image
FROM node:20-alpine AS builder

WORKDIR /build

COPY package*.json ./
RUN npm install --legacy-peer-deps

COPY prisma ./prisma
RUN npx prisma generate

COPY . .
RUN npm run build

# Production runtime stage: prod deps only, no dev tooling
FROM node:20-alpine AS production

WORKDIR /app

# Install dumb-init for proper signal handling
RUN apk add --no-cache dumb-init

# Install production dependencies
COPY package*.json ./
RUN npm install --omit=dev --legacy-peer-deps

# Copy Prisma files
COPY prisma ./prisma
COPY --from=builder /build/node_modules/.prisma ./node_modules/.prisma

# Copy built application
COPY --from=builder /build/dist ./dist

# Create non-root user
RUN addgroup -g 1001 -S nodejs && adduser -S nodejs -u 1001
USER nodejs

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "require('http').get('http://localhost:3001/health', (r) => {if (r.statusCode !== 200) throw new Error(r.statusCode)})"

# Use dumb-init to handle signals properly
ENTRYPOINT ["dumb-init", "--"]

# Start application
CMD ["node", "dist/main"]
