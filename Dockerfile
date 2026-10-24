# syntax=docker/dockerfile:1.7

FROM debian:trixie-slim AS build

ARG ASTERISK_VERSION=22.11.0
ARG ASTERISK_SHA256=3bd5ee040509a3d3cd9b1ba9520c18e6ec0a7e7981ca68c457dcd36ba3c54d94

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential pkg-config curl ca-certificates bzip2 patch file \
        libedit-dev libjansson-dev libsqlite3-dev uuid-dev libxml2-dev libssl-dev libsrtp2-dev libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/asterisk

RUN curl -fsSL -o /tmp/asterisk.tar.gz "https://downloads.asterisk.org/pub/telephony/asterisk/releases/asterisk-${ASTERISK_VERSION}.tar.gz" \
    && echo "${ASTERISK_SHA256}  /tmp/asterisk.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/asterisk.tar.gz --strip-components=1 \
    && rm /tmp/asterisk.tar.gz

RUN ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --libdir=/usr/lib \
        --with-pjproject-bundled --with-jansson --with-srtp --with-ssl --with-libcurl \
        --without-dahdi --without-pri --without-ss7 --without-tonezone --without-x11 --without-gtk2 \
    && make menuselect.makeopts

COPY config/server/modules.conf /tmp/modules/server.conf
COPY config/sim-gateway-simulator/modules.conf /tmp/modules/sim-gateway-simulator.conf

RUN modules="$(grep -h '^load' /tmp/modules/*.conf | sed 's/^load *= *//; s/\.so$//' | sort -u)" \
    && menuselect/menuselect --disable-all menuselect.makeopts \
    && menuselect/menuselect --disable BUILD_NATIVE --enable OPTIONAL_API menuselect.makeopts \
    && for module in $modules; do menuselect/menuselect --enable "$module" menuselect.makeopts; done \
    && make third-party NOISY_BUILD=yes \
    && make -j"$(nproc)" NOISY_BUILD=yes \
    && make install DESTDIR=/opt/asterisk \
    && rm -rf /opt/asterisk/var/run \
    && find /opt/asterisk -type f \( -name '*.so*' -o -path '*/sbin/asterisk' \) -exec sh -c 'file "$1" | grep -q ELF && strip --strip-unneeded "$1"' _ {} \; \
    && for module in $modules; do test -f "/opt/asterisk/usr/lib/asterisk/modules/$module.so" || { echo "$module wasn't built" >&2; exit 1; }; done

FROM debian:trixie-slim

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libedit2 libjansson4 libsqlite3-0 libuuid1 libxml2 libssl3t64 libsrtp2-1 libcurl4t64 gettext-base ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 10001 asterisk \
    && useradd --system --uid 10001 --gid 10001 --home-dir /var/lib/asterisk --shell /usr/sbin/nologin asterisk

COPY --from=build /opt/asterisk/ /

RUN ldconfig \
    && mkdir -p /etc/asterisk /var/lib/asterisk-data /var/run/asterisk /var/log/asterisk /var/spool/asterisk \
    && chown -R asterisk:asterisk /etc/asterisk /var/lib/asterisk /var/lib/asterisk-data /var/run/asterisk /var/log/asterisk /var/spool/asterisk

COPY config/ /etc/asterisk-templates/
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

USER 10001:10001

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
