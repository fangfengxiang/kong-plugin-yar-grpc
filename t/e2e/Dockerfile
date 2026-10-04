# Dockerfile — e2e test image for Kong plugin yar_grpc_bridge
#
# Extends the bridge e2e base image (OpenResty + PHP + Go + protoc + lua-yar-grpc).
# Installs lua-resty-yar-grpc-bridge v0.1.1 from GitHub (remote, self-contained)
# and lua-resty-http (needed by handler.lua for yar2grpc grpc_transport).
#
# Prerequisite: build the bridge e2e base image first:
#   make docker-base
#
# Build: docker build -t kong-yar-grpc-plugin-e2e -f t/e2e/Dockerfile t/e2e/
# Run:   docker run --rm -v "$(pwd):/app" -w /app kong-yar-grpc-plugin-e2e bash t/e2e/run_e2e.sh

FROM yar-grpc-bridge-e2e

# ── lua-resty-yar-grpc-bridge v0.1.1 (installed from GitHub, not local mount) ──
# The bridge is an OPM package (dist.ini, no luarocks rockspec). Clone the v0.1.1
# tag and copy lib/ into OpenResty's standard lualib path — the default
# lua_package_path (;;) discovers it, no BRIDGE_LIB env or volume mount needed.
RUN git clone --branch v0.1.1 --depth 1 \
        https://github.com/fangfengxiang/lua-resty-yar-grpc-bridge.git /tmp/bridge \
    && cp -r /tmp/bridge/lib/resty/yar_grpc_bridge \
        /usr/local/openresty/lualib/resty/ \
    && rm -rf /tmp/bridge

# ── lua-resty-http (needed by handler.lua for yar2grpc grpc_transport) ──
RUN /usr/local/openresty/luajit/bin/luarocks install lua-resty-http

ENV OPENRESTY_PREFIX=/usr/local/openresty

WORKDIR /app
