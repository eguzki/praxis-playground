FROM nginx:1.27-alpine

# Copy nginx configuration
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Create directory for JWKS (will be volume-mounted at runtime)
RUN mkdir -p /usr/share/nginx/html

EXPOSE 80
