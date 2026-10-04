# Dockerfile — e2e test image for Kong plugin yar_grpc_bridge
#
# Self-contained: builds FROM the public openresty/openresty:jammy image.
# No local pre-built base image, no git clone from GitHub.
#
# Lua dependencies installed via luarocks (from luarocks.org):
#   - lua-protobuf 0.5.3-1 (pinned — works around luarocks 3.13.0 fetch.lua bug)
#   - lua-resty-yar-grpc-bridge >= 0.1.2 (pulls lua-yar-grpc + lua-yar transitively)
#   - lua-resty-http
#
# The plugin itself (kong/) is COPY'd as source and loaded via nginx
# lua_package_path (see nginx_yar2grpc.conf @PREFIX@) — NOT luarocks install,
# because e2e runs against the in-tree source under test.
#
# Build: docker build -t kong-yar-grpc-plugin-e2e -f t/e2e/Dockerfile .
# Run:   docker run --rm -w /app kong-yar-grpc-plugin-e2e bash t/e2e/run_e2e.sh

FROM openresty/openresty:jammy

ENV DEBIAN_FRONTEND=noninteractive

# ── System deps: PHP + build tools + protoc ──
RUN apt-get update && apt-get install -y --no-install-recommends \
        tzdata \
        php8.1-cli \
        php8.1-dev \
        php8.1-curl \
        php8.1-mbstring \
        php-pear \
        libcurl4-openssl-dev \
        libxml2-dev \
        protobuf-compiler \
        build-essential \
        git \
        rsync \
        ca-certificates \
        curl \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

# ARM64: libcurl headers live in /usr/include/<multiarch>/curl/; yar's configure
# only checks /usr/include/curl/ — symlink so it resolves on aarch64 too.
RUN MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH)" \
    && if [ -d "/usr/include/${MULTIARCH}/curl" ] && [ ! -d /usr/include/curl ]; then \
        ln -s "/usr/include/${MULTIARCH}/curl" /usr/include/curl; \
    fi

# ── PHP yar + msgpack extensions ──
# Order matters: msgpack first (installs headers), then yar with
# --enable-msgpack (pecl can't pass it cleanly). Without --enable-msgpack,
# yar silently falls back to PHP serialize, which the Lua msgpack decoder
# misreads. zend.assertions=1 so scenario value assertions actually execute.
RUN pecl install msgpack \
    && cd /tmp && pecl download yar && tar xf yar-*.tgz && cd yar-*/ \
    && phpize && ./configure --enable-msgpack \
    && make -j"$(nproc)" && make install \
    && cd /tmp && rm -rf /tmp/yar-* \
    && echo "extension=msgpack.so" > "$(php-config --ini-dir)/20-msgpack.ini" \
    && echo "extension=yar.so"      > "$(php-config --ini-dir)/30-yar.ini" \
    && echo "zend.assertions=1"     > "$(php-config --ini-dir)/99-assertions.ini"

# ── Go toolchain (apt version too old; install latest stable from go.dev) ──
# Auto-detects arch (amd64/arm64) for Apple Silicon + x86 compatibility.
RUN ARCH="$(uname -m)" \
    && case "$ARCH" in \
        x86_64)  GOARCH="amd64" ;; \
        aarch64) GOARCH="arm64" ;; \
        *) echo "unsupported arch: $ARCH"; exit 1 ;; \
    esac \
    && GO_VER="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -1)" \
    && curl -fsSL "https://go.dev/dl/${GO_VER}.linux-${GOARCH}.tar.gz" \
       | tar -C /usr/local -xzf -
ENV PATH="${PATH}:/usr/local/go/bin:/root/go/bin"
ENV GOPATH=/root/go
ENV GOFLAGS=-mod=mod

# ── Go protoc plugins (proto/gen.sh generates Go gRPC code) ──
RUN go install google.golang.org/protobuf/cmd/protoc-gen-go@latest \
    && go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest

# ── Lua dependencies (luarocks install from luarocks.org — NO git clone) ──
# lua-protobuf pinned to 0.5.3-1: luarocks 3.13.0 fetch.lua has a bug where a
# mirror download failure on 0.5.2-1 crashes (concatenates a nil error). Pinning
# the good revision bypasses it. lua-resty-yar-grpc-bridge then pulls
# lua-yar-grpc + lua-yar transitively (lua-protobuf already satisfied).
RUN /usr/local/openresty/luajit/bin/luarocks install lua-protobuf 0.5.3-1 \
    && /usr/local/openresty/luajit/bin/luarocks install lua-resty-yar-grpc-bridge \
    && /usr/local/openresty/luajit/bin/luarocks install lua-resty-http

# ── Plugin source (COPY'd; loaded via nginx lua_package_path, not luarocks) ──
COPY kong/ /app/kong/

# ── e2e test assets (proto, Go server/client, PHP client, nginx confs, scripts) ──
COPY t/ /app/t/

ENV OPENRESTY_PREFIX=/usr/local/openresty

# ── Print installed versions (build-log visibility for version-drift debugging) ──
RUN echo "=== Installed dependency versions ===" \
    && /usr/local/openresty/nginx/sbin/nginx -v 2>&1 \
    && /usr/local/openresty/luajit/bin/luarocks list \
    && php -m | grep -iE '^(yar|msgpack)$' \
    && php -r 'echo "zend.assertions=" . ini_get("zend.assertions") . "\n";' \
    && go version \
    && protoc --version \
    && protoc-gen-go --version \
    && echo "=== versions OK ==="

WORKDIR /app
