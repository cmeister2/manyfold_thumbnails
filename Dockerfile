ARG MANYFOLD_IMAGE=manyfold3d/manyfold-solo:0.153.0@sha256:161109b917a158b5efd8478a437e9900db7bdc57235c167aa70d5ad69425fc31
FROM ${MANYFOLD_IMAGE}

COPY docker/local-setup.rb /usr/src/app/docker/local-setup.rb
RUN sed -i '/^bundle exec rails db:prepare:with_data$/a bundle exec rails runner docker/local-setup.rb' /usr/src/app/bin/docker-entrypoint.sh

ENTRYPOINT ["/bin/ash", "-ec", "mkdir -p /config/models; chown $PUID:$PGID /config /config/models; exec /init"]
