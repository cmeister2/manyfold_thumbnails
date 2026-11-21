ARG MANYFOLD_IMAGE=manyfold3d/manyfold-solo:0.154.3@sha256:958e0266bccfcdb8cb928f38a902049fffdfbf4c29520ba612137fb3cc2835c9
FROM ${MANYFOLD_IMAGE}

COPY docker/local-setup.rb /usr/src/app/docker/local-setup.rb
RUN sed -i '/^bundle exec rails db:prepare:with_data$/a bundle exec rails runner docker/local-setup.rb' /usr/src/app/bin/docker-entrypoint.sh

ENTRYPOINT ["/bin/ash", "-ec", "mkdir -p /config/models; chown $PUID:$PGID /config /config/models; exec /init"]
