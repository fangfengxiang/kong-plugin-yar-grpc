# Makefile — kong-plugin-yar-grpc
#
# Common targets:
#   make lint        — luacheck + stylua --check (static analysis + format)
#   make test        — unit tests (busted, mocked Kong PDK — no Kong binary)
#   make e2e         — end-to-end interop (local: OpenResty + PHP + Go)
#   make docker-e2e  — end-to-end in Docker (self-contained, no local deps)
#   make clean       — remove test artifacts + nginx temp dirs
#
# Docker helpers:
#   make docker-base  — build bridge base image from GitHub (first time only)
#   make docker-build — build Kong plugin e2e image on top of base

ROOT := $(shell pwd)

# OpenResty install prefix (contains nginx/sbin/nginx, luajit/bin/luarocks).
# macOS: auto-detected via `brew --prefix openresty` (no hardcoded path —
#        adapts to Apple Silicon /opt/homebrew and Intel /usr/local).
# Linux/other: falls back to the standard source-build path.
# Override: make e2e OPENRESTY_PREFIX=/path/to/openresty
OPENRESTY_PREFIX ?= $(shell brew --prefix openresty 2>/dev/null || echo /usr/local/openresty)
NGINX = $(OPENRESTY_PREFIX)/nginx/sbin/nginx
LUAROCKS = $(OPENRESTY_PREFIX)/luajit/bin/luarocks

# Bridge dependency — installed remotely from GitHub, not local sibling dir
BRIDGE_REPO ?= https://github.com/fangfengxiang/lua-resty-yar-grpc-bridge.git
BRIDGE_VERSION ?= v0.1.1

# Lua source dirs for lint (config in .luacheckrc + .stylua.toml)
LUA_SRC := kong/

.PHONY: lint test e2e docker-base docker-build docker-e2e clean

# ── Lint: luacheck (static analysis) + stylua --check (format) ──
# luacheck reads .luacheckrc (globals ngx/kong, ignore self)
# stylua reads .stylua.toml (4-space indent, 120-col, NoSingleTable)
lint:
	luacheck $(LUA_SRC)
	stylua --check $(LUA_SRC)

# ── Unit tests (BDD with busted, mocked Kong PDK — no OpenResty/Kong binary) ──
# Tests handler logic: config signature, value coercion, URI routing, 404 path.
test:
	busted -v t/00-unit/

# ── E2E interop tests (local: requires OpenResty + PHP + Go + protoc) ──
# Scenario 1: PHP Yar → Kong (yar2grpc) → Go gRPC
# Scenario 2: Go gRPC → Kong (grpc2yar) → PHP Yar
# Both scenarios run with json + msgpack packagers.
e2e:
	OPENRESTY_PREFIX=$(OPENRESTY_PREFIX) bash t/e2e/run_e2e.sh

# ── Docker e2e (self-contained: builds images, no local deps needed) ──
# Base image provides OpenResty + PHP + Go + protoc + lua-yar-grpc runtime.
# Built once from GitHub and cached locally; subsequent runs skip the clone.
docker-base:
	@docker image inspect yar-grpc-bridge-e2e >/dev/null 2>&1 || { \
		echo "Building bridge base image from $(BRIDGE_REPO) @ $(BRIDGE_VERSION)..."; \
		tmpdir=$$(mktemp -d); \
		git clone --branch $(BRIDGE_VERSION) --depth 1 $(BRIDGE_REPO) $$tmpdir/bridge; \
		docker build -t yar-grpc-bridge-e2e -f $$tmpdir/bridge/t/e2e/Dockerfile $$tmpdir/bridge/t/e2e/; \
		rm -rf $$tmpdir; \
	}

docker-build: docker-base
	docker build -t kong-yar-grpc-plugin-e2e -f t/e2e/Dockerfile t/e2e/

docker-e2e: docker-build
	docker run --rm -v "$(ROOT):/app" -w /app kong-yar-grpc-plugin-e2e bash t/e2e/run_e2e.sh

# ── Clean: remove test artifacts + nginx temp directories ──
# *_temp: uwsgi_temp, scgi_temp, proxy_temp, fastcgi_temp, client_body_temp
clean:
	rm -rf t/e2e/.run *_temp
