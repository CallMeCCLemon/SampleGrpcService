FROM --platform=$BUILDPLATFORM node:22-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
ARG VITE_GITHUB_REPO
ARG VITE_GOOGLE_CLIENT_ID
ENV VITE_GITHUB_REPO=$VITE_GITHUB_REPO
ENV VITE_GOOGLE_CLIENT_ID=$VITE_GOOGLE_CLIENT_ID
RUN npm run build

FROM nginx:alpine
COPY --from=builder /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
# A per-commit final layer gives every build a distinct manifest digest, so
# registry-prune can never delete a digest the live tag also points at.
ARG GIT_SHA=unspecified
RUN echo "$GIT_SHA" > /etc/web.build-sha
EXPOSE 80
