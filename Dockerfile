ARG MANYFOLD_IMAGE=manyfold3d/manyfold-solo:0.154.1@sha256:f1b7784fb63aec500fca61081d3f970948fc652ad16ecdc5d57cd3c0c925127f
FROM ${MANYFOLD_IMAGE}

COPY docker/local-setup.rb /usr/src/app/docker/local-setup.rb
RUN sed -i '/^bundle exec rails db:prepare:with_data$/a bundle exec rails runner docker/local-setup.rb' /usr/src/app/bin/docker-entrypoint.sh

ENTRYPOINT ["/bin/ash", "-ec", "mkdir -p /config/models; chown $PUID:$PGID /config /config/models; exec /init"]
