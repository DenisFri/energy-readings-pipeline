FROM nginx:1.27-alpine

# Remove default config
RUN rm /etc/nginx/conf.d/default.conf

# Copy nginx template and static files
COPY nginx.conf.template /etc/nginx/templates/default.conf.template
COPY index.html /usr/share/nginx/html/index.html

# Default env vars for envsubst (overridden at runtime)
ENV INGESTION_API_HOST=ingestion-api \
    INGESTION_API_PORT=8000 \
    PROCESSING_SERVICE_HOST=processing-service \
    PROCESSING_SERVICE_PORT=8001

EXPOSE 80

# nginx:alpine image auto-runs envsubst on /etc/nginx/templates/*.template
# and writes results to /etc/nginx/conf.d/ before starting nginx
