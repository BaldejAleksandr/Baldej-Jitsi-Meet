# File sharing service image - Образ сервиса обмена файлами
# Sources are in ./app, unpacked by the jitsi_file_sharing role - Исходники лежат в ./app, их распаковывает роль jitsi_file_sharing
FROM node:22-alpine AS build
WORKDIR /app
COPY app/package.json app/package-lock.json ./
RUN npm ci
COPY app/ ./
COPY patch.sh /patch.sh
RUN sh /patch.sh && npm run build && npm prune --omit=dev

FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY --from=build /app/package.json ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
USER node
EXPOSE 3000
CMD ["node", "dist/index.js"]
