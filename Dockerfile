ARG MANYFOLD_IMAGE=manyfold3d/manyfold-solo:0.152.0@sha256:37e3e76ce59eda468e6f7c335d5fbdfb0bf700ca6312da6dd87881807eda44ee
FROM ${MANYFOLD_IMAGE}

COPY docker/local-setup.rb /usr/src/app/docker/local-setup.rb
RUN sed -i '/^bundle exec rails db:prepare:with_data$/a bundle exec rails runner docker/local-setup.rb' /usr/src/app/bin/docker-entrypoint.sh

ENTRYPOINT ["/bin/ash", "-ec", "mkdir -p /config/models; chown $PUID:$PGID /config /config/models; exec /init"]
