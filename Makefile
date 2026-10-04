# Makefile — kong-plugin-yar-grpc
#
# Common targets:
#   make lint        — luacheck + stylua --check (static analysis + format)
#   make test        — unit tests (busted, mocked Kong PDK — no Kong binary)
#   make e2e         — end-to-end interop (local: OpenResty + PHP + Go)
#   make docker-e2e  — plugin-logic e2e in Docker (bare OpenResty + content_by_lua)
#   make docker-kong-e2e — Kong integration e2e (real Kong Gateway, DB-less)
#   make clean       — remove test artifacts + nginx temp dirs
#
# Docker helpers:
#   make docker-build      — build plugin-logic e2e image (openresty base)
#   make docker-e2e        — run plugin-logic e2e inside the image
#   make docker-kong-build — build Kong integration e2e image (kong:3.6-ubuntu base)
#   make docker-kong-e2e   — run Kong integration e2e inside the image

ROOT := $(shell pwd)

# OpenResty install prefix (contains nginx/sbin/nginx, luajit/bin/luarocks).
# macOS: auto-detected via `brew --prefix openresty` (no hardcoded path —
#        adapts to Apple Silicon /opt/homebrew and Intel /usr/local).
# Linux/other: falls back to the standard source-build path.
# Override: make e2e OPENRESTY_PREFIX=/path/to/openresty
OPENRESTY_PREFIX ?= $(shell brew --prefix openresty 2>/dev/null || echo /usr/local/openresty)
NGINX = $(OPENRESTY_PREFIX)/nginx/sbin/nginx
LUAROCKS = $(OPENRESTY_PREFIX)/luajit/bin/luarocks

# Lua source dirs for lint (config in .luacheckrc + .stylua.toml)
LUA_SRC := kong/

.PHONY: lint test e2e docker-build docker-e2e docker-kong-build docker-kong-e2e clean

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

# ── Docker e2e (self-contained: builds from public openresty base image) ──
# Image installs PHP + Go + protoc + Lua deps (luarocks install) and COPYs
# the plugin source (kong/) + test assets (t/). No local mount, no git clone.
# To inspect logs after a run, mount the .run dir:
#   -v "$(pwd)/t/e2e/.run:/app/t/e2e/.run"
E2E_IMAGE ?= kong-yar-grpc-plugin-e2e

docker-build:
	docker build -t $(E2E_IMAGE) -f t/e2e/Dockerfile .

docker-e2e: docker-build
	docker run --rm -w /app $(E2E_IMAGE) bash t/e2e/run_e2e.sh

# ── Kong integration e2e (real Kong Gateway, DB-less mode) ──
# Unlike docker-e2e (bare OpenResty + content_by_lua, tests plugin logic only),
# this runs the REAL Kong Gateway with KONG_DATABASE=off + declarative config,
# exercising Kong's own paths: schema validation, DB-less load, router matching,
# plugin binding to routes.
# To inspect logs after a run, mount the .run dir:
#   -v "$(pwd)/t/kong-e2e/.run:/app/t/kong-e2e/.run"
KONG_E2E_IMAGE ?= kong-yar-grpc-integration-e2e

docker-kong-build:
	docker build -t $(KONG_E2E_IMAGE) -f t/kong-e2e/Dockerfile .

docker-kong-e2e: docker-kong-build
	docker run --rm -w /app $(KONG_E2E_IMAGE) bash t/kong-e2e/run_kong_e2e.sh

# ── Clean: remove test artifacts + nginx temp directories ──
# *_temp: uwsgi_temp, scgi_temp, proxy_temp, fastcgi_temp, client_body_temp
clean:
	rm -rf t/e2e/.run t/kong-e2e/.run *_temp
