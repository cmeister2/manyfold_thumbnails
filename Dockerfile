ARG MANYFOLD_IMAGE=manyfold3d/manyfold-solo:0.154.4@sha256:ecffe1f17f940646e76a089578e0220e51a9e753f0ef31c68638cbd505880916
FROM ${MANYFOLD_IMAGE}

COPY docker/local-setup.rb /usr/src/app/docker/local-setup.rb
RUN sed -i '/^bundle exec rails db:prepare:with_data$/a bundle exec rails runner docker/local-setup.rb' /usr/src/app/bin/docker-entrypoint.sh

ENTRYPOINT ["/bin/ash", "-ec", "mkdir -p /config/models; chown $PUID:$PGID /config /config/models; exec /init"]
