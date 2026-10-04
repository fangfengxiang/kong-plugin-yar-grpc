# Dockerfile — Kong integration e2e for plugin yar_grpc_bridge
#
# Multi-stage build (pattern follows apisix-plugin-yar-grpc/t/e2e/Dockerfile):
#   Stage 1 (golang:bookworm): compile Go gRPC server/client + generate .pb
#   Stage 2 (kong:3.6-ubuntu): PHP + system luarocks (Lua 5.3, no 65536 limit) +
#             LuaJIT-ABI .so via luarocks config variables.LUA_INCDIR
#
# This image runs the REAL Kong Gateway in DB-less mode, exercising Kong's own
# paths: config schema validation, DB-less declarative load, router matching,
# plugin binding to routes (access phase).
#
# Build: docker build -t kong-yar-grpc-integration-e2e -f t/kong-e2e/Dockerfile .
# Run:   docker run --rm kong-yar-grpc-integration-e2e

# ── Stage 1: Go builder + proto generation ──
FROM golang:bookworm AS builder
ENV GOPROXY=https://goproxy.cn,direct
RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*
RUN go install google.golang.org/protobuf/cmd/protoc-gen-go@latest && \
    go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
ENV PATH="/root/go/bin:${PATH}"
WORKDIR /build
COPY t/e2e/proto/calculator.proto t/e2e/proto/gen.sh proto/
COPY t/e2e/go/ go/
RUN bash proto/gen.sh && \
    cd go && \
    go build -buildvcs=false -o /out/grpc_server ./grpc_server && \
    go build -buildvcs=false -o /out/grpc_client ./grpc_client

# ── Stage 2: Kong runtime ──
FROM kong:3.6-ubuntu
USER root
ENV DEBIAN_FRONTEND=noninteractive

# Enable Ubuntu universe (php8.1 + luarocks live in universe)
RUN sed -ri 's/^# *(.*universe.*)$/\1/' /etc/apt/sources.list || true

# System deps: PHP + build tools + protoc + system luarocks (runs under Lua 5.3,
# no LuaJIT 65536-constant limit when loading luarocks.org manifest).
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
        luarocks \
    && rm -rf /var/lib/apt/lists/*

# ARM64: libcurl headers symlink (yar configure only checks /usr/include/curl/)
RUN MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH)" \
    && if [ -d "/usr/include/${MULTIARCH}/curl" ] && [ ! -d /usr/include/curl ]; then \
        ln -s "/usr/include/${MULTIARCH}/curl" /usr/include/curl; \
    fi

# PHP yar + msgpack extensions.
# msgpack first (installs headers), then yar with --enable-msgpack.
# Without --enable-msgpack, yar silently falls back to PHP serialize.
# zend.assertions=1 so scenario value assertions actually execute.
RUN pecl install msgpack \
    && cd /tmp && pecl download yar && tar xf yar-*.tgz && cd yar-*/ \
    && phpize && ./configure --enable-msgpack \
    && make -j"$(nproc)" && make install \
    && cd /tmp && rm -rf /tmp/yar-* \
    && echo "extension=msgpack.so" > "$(php-config --ini-dir)/20-msgpack.ini" \
    && echo "extension=yar.so"      > "$(php-config --ini-dir)/30-yar.ini" \
    && echo "zend.assertions=1"     > "$(php-config --ini-dir)/99-assertions.ini"

# Lua dependencies: Kong ships its own luarocks 3.9.2 at /usr/local/bin/luarocks
# (shebang -> LuaJIT 5.1), which hits the 65536-constant limit loading the
# luarocks.org manifest. The apt-installed /usr/bin/luarocks (shebang
# -> /usr/bin/env lua-any) runs under Lua 5.3 and has NO such limit, while still
# compiling .so against LuaJIT headers via variables.LUA_INCDIR. Use the absolute
# path to bypass PATH precedence (/usr/local/bin precedes /usr/bin).
# --tree=/usr/local puts .lua/.so into /usr/local/share/lua/5.1/ and
# /usr/local/lib/lua/5.1/ (Kong's LUA_PATH).
# lua-protobuf pinned to 0.5.3-1: luarocks fetch.lua bug workaround (see
# lua-resty-yar-grpc-bridge/t/e2e/Dockerfile comment for details).
RUN mkdir -p /root/.luarocks \
    && /usr/bin/luarocks config variables.LUA_INCDIR /usr/local/openresty/luajit/include/luajit-2.1 \
    && /usr/bin/luarocks install --tree=/usr/local lua-protobuf 0.5.3-1 \
    && /usr/bin/luarocks install --tree=/usr/local lua-resty-yar-grpc-bridge \
    && /usr/bin/luarocks install --tree=/usr/local lua-resty-http

# Patch Kong nginx template: inject `set` + `add_trailer` directives at SERVER
# block level (before the first rewrite_by_lua_block) so gRPC trailers
# (grpc-status, grpc-message) are emitted for ALL locations.
#
# Why patch the template (not kong.conf nginx_proxy_* directives):
#   Kong's prefix-based directive collection (nginx_proxy_<name>=<value>) only
#   supports ONE value per directive name. We need two `set` directives
#   ($grpc_status, $grpc_message) sharing the name "set" -- impossible via env.
#   The template's `nginx_proxy_directives` loop is server-block level, but it's
#   also driven by the same prefix-based collection, so same limitation applies.
#   sed-patching the template is the only way to inject multiple same-name `set`.
#
# Why server level (not location / level like before):
#   Previously patched after `set $kong_proxy_mode 'http';` inside location /.
#   gRPC requests DO route through location / in Kong, so that should work, but
#   server level is strictly more correct (covers @unbuffered etc. too) and
#   removes location-routing as a variable when diagnosing trailer issues.
#
# `$done` guard: template has 3 rewrite_by_lua_block occurrences (proxy server,
# admin server, etc.); we only patch the first (proxy server).
RUN TMPL=/usr/local/share/lua/5.1/kong/templates/nginx_kong.lua \
    && perl -i -pe 'BEGIN { $d = 0 } if (/rewrite_by_lua_block \{/ && !$d++) { $_ = "    set \$service_name \x27\x27;\n    set \$grpc_status \x27\x27;\n    set \$grpc_message \x27\x27;\n    add_trailer grpc-status \$grpc_status always;\n    add_trailer grpc-message \$grpc_message always;\n" . $_; }' "$TMPL" \
    && grep -c grpc_status "$TMPL" | xargs echo "patched lines containing grpc_status:"

# Plugin source -> Kong default plugin path (kong.plugins.<name> namespace,
# resolved via KONG_LUA_PACKAGE_PATH which includes /usr/local/share/lua/5.1/)
COPY kong/plugins/ /usr/local/share/lua/5.1/kong/plugins/

# e2e assets (proto, Go server/client, PHP client/server, kong.yml, scripts)
COPY t/ /app/t/

# Pre-built Go binaries + .pb descriptor from builder stage.
# Path /app/t/kong-e2e/.run/bin matches run_kong_e2e.sh BIN= (D=/app/t/kong-e2e),
# so the "skip rebuild if binary exists" check finds them and skips `go build`
# (Go toolchain is not installed in this runtime stage).
COPY --from=builder /out/grpc_server /out/grpc_client /app/t/kong-e2e/.run/bin/
COPY --from=builder /build/proto/calculator.pb /app/t/e2e/proto/calculator.pb

# Kong DB-less mode + custom plugin loading
ENV KONG_DATABASE=off
ENV KONG_PLUGINS=bundled,yar_grpc_bridge
# proxy_listen: http2 on :8000 enables gRPC routes (h2c cleartext); HTTP/1.1
# still works on the same port (nginx negotiates), so PHP Yar -> :8000/api OK.
ENV KONG_PROXY_LISTEN="0.0.0.0:8000 http2"
ENV KONG_ADMIN_LISTEN=127.0.0.1:8001

WORKDIR /app
CMD ["bash", "t/kong-e2e/run_kong_e2e.sh"]
