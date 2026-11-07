FROM node:22-bookworm-slim
WORKDIR /app
COPY package.json package-lock.json* ./
RUN if [ -f package-lock.json ]; then npm ci --omit=dev; else npm install --omit=dev; fi
COPY . .
# App processes run with /work as cwd: partition logs, offsets and the
# dead-letter file land there, on the bind mount the harness controls.
WORKDIR /work
