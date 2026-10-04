package = "kong-plugin-yar-grpc"
version = "0.1.0-1"

source = {
    url = "https://github.com/fangfengxiang/kong-plugin-yar-grpc.git",
    branch = "main",
}

description = {
    summary = "Kong custom plugin: YAR ↔ gRPC protocol bridge",
    detailed = [[
        Kong custom plugin that bridges YAR RPC and gRPC protocols.
        Reuses the host-agnostic orchestration + HTTP entry layer from
        lua-resty-yar-grpc-bridge. Supports both directions:
        grpc2yar (gRPC client → PHP Yar) and yar2grpc (PHP Yar → gRPC).
    ]],
    homepage = "https://github.com/fangfengxiang/kong-plugin-yar-grpc",
    license = "Apache 2.0",
    maintainer = "yar-group",
}

dependencies = {
    "lua-resty-yar-grpc-bridge",
    "lua-resty-http",
}

build = {
    type = "builtin",
    modules = {
        ["kong.plugins.yar_grpc_bridge.handler"] = "kong/plugins/yar_grpc_bridge/handler.lua",
        ["kong.plugins.yar_grpc_bridge.schema"] = "kong/plugins/yar_grpc_bridge/schema.lua",
    },
}
