# kong-plugin-yar-grpc

Kong custom plugin: YAR ↔ gRPC protocol bridge for Kong Gateway.

Reuses the host-agnostic orchestration + OpenResty HTTP entry from
[`lua-resty-yar-grpc-bridge`](../lua-resty-yar-grpc-bridge) (overview-5 职责拆分后，
编排层 `grpc2yar.handle` / `yar2grpc._dispatch` 与 HTTP 入口层已分离）。

## Architecture

```
gRPC client ──HTTP/2──► Kong (plugin:access) ──► grpc2yar_endpoint.serve()
                                                └─► grpc2yar.handle (编排)
                                                    └─► lua-yar client ──► PHP Yar Server

PHP Yar client ──HTTP/1.1──► Kong (plugin:access) ──► yar2grpc_endpoint.handle()
                                                   └─► yar2grpc._dispatch (编排)
                                                       └─► grpc_transport ──► Go gRPC Server
```

Kong runs on OpenResty → `ngx.*` available → bridge `host.lua` abstraction + entry modules
work as-is. Plugin wires Kong's phase lifecycle (access) to the bridge entry modules.

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
# install bridge dep
luarocks make ../lua-resty-yar-grpc-bridge/*.rockspec

# unit tests (busted)
busted t/00-unit/

# e2e (Docker: Kong + PHP Yar + Go gRPC)
bash t/e2e/run_e2e.sh
```
