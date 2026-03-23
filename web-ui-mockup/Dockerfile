# Kafka User Provisioning — Web UI (static mockup)
# Run on Helper Node with Docker or Podman. Single container, no backend yet.
FROM nginx:alpine

# Remove default content and use our own
RUN rm -rf /usr/share/nginx/html/*

COPY index.html confluent-wordmark.png /usr/share/nginx/html/

# Optional: default.conf for SPA or custom root
RUN echo 'server { listen 80; root /usr/share/nginx/html; index index.html; location / { try_files $uri $uri/ /index.html; } }' > /etc/nginx/conf.d/default.conf

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
