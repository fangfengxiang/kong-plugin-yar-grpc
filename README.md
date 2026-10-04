# kong-plugin-yar-grpc

[English](README.md) | [简体中文](README.zh.md)

[![CI](https://github.com/fangfengxiang/kong-plugin-yar-grpc/actions/workflows/ci.yml/badge.svg)](https://github.com/fangfengxiang/kong-plugin-yar-grpc/actions/workflows/ci.yml)
[![Kong](https://img.shields.io/badge/Kong-Gateway-blue.svg)](https://konghq.com/kong-gateway/)
[![License](https://img.shields.io/badge/license-Apache_2.0-blue.svg)](LICENSE)

Kong custom plugin: YAR &harr; gRPC protocol bridge for Kong Gateway.

Reuses the host-agnostic orchestration + OpenResty HTTP entry from
[`lua-resty-yar-grpc-bridge`](https://github.com/fangfengxiang/lua-resty-yar-grpc-bridge).

## Dependencies

| Package | Version | Required when |
|---|---|---|
| `lua-resty-yar-grpc-bridge` | >= 0.1.1 | always |
| `lua-resty-http` | >= 0.17 | yar2grpc direction only (gRPC backend HTTP transport) |

## Quick Start

### Install

```bash
luarocks install kong-plugin-yar-grpc
```

### grpc2yar: gRPC client &rarr; Kong &rarr; PHP Yar server

```yaml
# kong.yml (DB-less declarative config)
_format_version: "3.0"
plugins:
- name: yar_grpc_bridge
  config:
    direction: grpc2yar
    services:
      Calculator:
        proto: /etc/kong/proto/calc.pb   # compiled protobuf descriptor (.pb)
        url: http://php-yar:8888/api      # PHP Yar server endpoint
        options:
          timeout: 5000
    yar_options:
      timeout: 3000
    max_payload_bytes: 8388608
```

```bash
# gRPC client → Kong → PHP Yar server
grpcurl -plaintext -d '{"a":15,"b":27}' localhost:8000 calculator.Calculator/Add
# → {"result":42}
```

### yar2grpc: PHP Yar client &rarr; Kong &rarr; gRPC server

```yaml
# kong.yml
_format_version: "3.0"
plugins:
- name: yar_grpc_bridge
  config:
    direction: yar2grpc
    services:
      Calculator:
        proto: /etc/kong/proto/calc.pb
    grpc_backend_url: http://go-grpc:50052   # HTTP/gRPC bridge of Go backend
    yar_path_prefix: /api/                     # URI prefix for service extraction
```

```php
<?php
// PHP Yar client → Kong → Go gRPC server
$client = new Yar_Client("http://localhost:8000/api/Calculator");
echo $client->add(15, 27);  // 42
```

## Architecture

```
gRPC client ──HTTP/2──► Kong (plugin:access) ──► grpc2yar_endpoint.serve()
                                                └─► grpc2yar.handle (orchestration)
                                                    └─► lua-yar client ──► PHP Yar Server

PHP Yar client ──HTTP/1.1──► Kong (plugin:access) ──► yar2grpc_endpoint.handle()
                                                   └─► yar2grpc._dispatch (orchestration)
                                                       └─► grpc_transport ──► Go gRPC Server
```

Kong runs on OpenResty &rarr; `ngx.*` available &rarr; bridge `host.lua` abstraction + entry modules
work as-is. Plugin wires Kong's phase lifecycle (`access`) to the bridge entry modules.

## Config schema (declarative)

```yaml
plugins:
- name: yar_grpc_bridge
  config:
    direction: grpc2yar        # grpc2yar | yar2grpc
    services:
      Calculator:
        proto: /etc/kong/proto/calc.pb
        url: http://php-yar:8888/api
        options:
          timeout: 5000
    yar_options:
      timeout: 3000
    max_payload_bytes: 8388608
```

## Files

- `kong/plugins/yar_grpc_bridge/handler.lua` — access-phase handler
- `kong/plugins/yar_grpc_bridge/schema.lua` — plugin config schema
- `t/` — BDD (busted) + e2e (Docker) tests

## Development

```bash
# lint (luacheck + stylua)
make lint

# unit tests (busted)
make test

# e2e tests (Docker: Kong + PHP Yar + Go gRPC, fully self-contained)
make docker-e2e
```

## License

Apache-2.0 — see [LICENSE](LICENSE).
