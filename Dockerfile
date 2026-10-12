ARG MANYFOLD_IMAGE=manyfold3d/manyfold-solo:0.151.0@sha256:772bcb18f0cb69d4fd0630d4676516f34fb37e42c3ac9d65eea5f173728e818e
FROM ${MANYFOLD_IMAGE}

COPY docker/local-setup.rb /usr/src/app/docker/local-setup.rb
COPY lib/manyfold_thumbnails/vendor /opt/manyfold-thumbnails/vendor
RUN case "$(uname -m)" in \
      x86_64) target=x86_64-unknown-linux-musl ;; \
      aarch64) target=aarch64-unknown-linux-musl ;; \
      *) echo "Unsupported Catwalk architecture" >&2; exit 1 ;; \
    esac && cp "/opt/manyfold-thumbnails/vendor/$target/catwalk" /usr/local/bin/catwalk \
    && chmod 755 /usr/local/bin/catwalk
RUN sed -i '/^bundle exec rails db:prepare:with_data$/a bundle exec rails runner docker/local-setup.rb' /usr/src/app/bin/docker-entrypoint.sh

ENTRYPOINT ["/bin/ash", "-ec", "mkdir -p /config/models; chown $PUID:$PGID /config /config/models; exec /init"]
