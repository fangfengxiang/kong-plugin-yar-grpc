# kong-plugin-yar-grpc

[English](README.md) | [简体中文](README.zh.md)

[![CI](https://github.com/fangfengxiang/kong-plugin-yar-grpc/actions/workflows/ci.yml/badge.svg)](https://github.com/fangfengxiang/kong-plugin-yar-grpc/actions/workflows/ci.yml)
[![Kong](https://img.shields.io/badge/Kong-Gateway-blue.svg)](https://konghq.com/kong-gateway/)
[![LuaRocks](https://img.shields.io/luarocks/v/fangfengxiang/kong-plugin-yar-grpc)](https://luarocks.org/modules/fangfengxiang/kong-plugin-yar-grpc)
[![License](https://img.shields.io/badge/license-Apache_2.0-blue.svg)](LICENSE)

Kong 自定义插件：YAR &harr; gRPC 协议桥接，适用于 Kong Gateway。

复用
[`lua-resty-yar-grpc-bridge`](https://github.com/fangfengxiang/lua-resty-yar-grpc-bridge)
的协议无关编排层与 OpenResty HTTP 入口层。

## 依赖

| 包名 | 版本 | 适用场景 |
|---|---|---|
| `lua-resty-yar-grpc-bridge` | >= 0.1.2 | 始终需要 |
| `lua-resty-http` | >= 0.17 | 仅 yar2grpc 方向（gRPC 后端 HTTP 传输） |

## 快速开始

### 安装

```bash
luarocks install kong-plugin-yar-grpc
```

### grpc2yar：gRPC 客户端 &rarr; Kong &rarr; PHP Yar 服务端

```yaml
# kong.yml（DB-less 声明式配置）
_format_version: "3.0"
plugins:
- name: yar_grpc_bridge
  config:
    direction: grpc2yar
    services:
      Calculator:
        proto: /etc/kong/proto/calc.pb   # 编译后的 protobuf 描述符（.pb）
        url: http://php-yar:8888/api      # PHP Yar 服务端地址
        options:
          timeout: 5000
    yar_options:
      timeout: 3000
    max_payload_bytes: 8388608
```

```bash
# gRPC 客户端 → Kong → PHP Yar 服务端
grpcurl -plaintext -d '{"a":15,"b":27}' localhost:8000 calculator.Calculator/Add
# → {"result":42}
```

### yar2grpc：PHP Yar 客户端 &rarr; Kong &rarr; gRPC 服务端

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
    grpc_backend_url: http://go-grpc:50052   # Go 后端的 HTTP/gRPC 桥接地址
    yar_path_prefix: /api/                     # 服务名提取的 URI 前缀
```

```php
<?php
// PHP Yar 客户端 → Kong → Go gRPC 服务端
$client = new Yar_Client("http://localhost:8000/api/Calculator");
echo $client->add(15, 27);  // 42
```

## 架构

```
gRPC 客户端 ──HTTP/2──► Kong (plugin:access) ──► grpc2yar_endpoint.serve()
                                                  └─► grpc2yar.handle (编排)
                                                      └─► lua-yar 客户端 ──► PHP Yar 服务端

PHP Yar 客户端 ──HTTP/1.1──► Kong (plugin:access) ──► yar2grpc_endpoint.handle()
                                                     └─► yar2grpc._dispatch (编排)
                                                         └─► grpc_transport ──► Go gRPC 服务端
```

Kong 运行于 OpenResty &rarr; `ngx.*` 可用 &rarr; 桥接库 `host.lua` 抽象层与入口模块
直接可用。插件将 Kong 的生命周期阶段（`access`）接入桥接库入口模块。

## 配置 Schema（声明式）

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

## 文件结构

- `kong/plugins/yar_grpc_bridge/handler.lua` — access 阶段处理器
- `kong/plugins/yar_grpc_bridge/schema.lua` — 插件配置 Schema
- `t/` — BDD 单元测试（busted）+ e2e 端到端测试（Docker）

## 开发

```bash
# 代码检查（luacheck + stylua）
make lint

# 单元测试（busted）
make test

# e2e 端到端测试（Docker：Kong + PHP Yar + Go gRPC，完全自包含）
make docker-e2e
```

## 许可协议

[Apache License 2.0](LICENSE)
