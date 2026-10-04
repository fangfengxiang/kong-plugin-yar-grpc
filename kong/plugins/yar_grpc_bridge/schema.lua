-- kong/plugins/yar_grpc_bridge/schema.lua
-- Plugin config schema for Kong declarative config (DB-less) or database mode.
--
-- Fields:
--   direction         — grpc2yar | yar2grpc (required)
--   services          — map of service_name → { proto, url, methods, options }
--   yar_options       — global YAR client options (timeout, packager, etc.)
--   max_payload_bytes — request body size limit (default 8MB)
--   grpc_backend_url  — HTTP bridge URL of gRPC backend (yar2grpc only)
--   yar_path_prefix   — URI prefix for service extraction (yar2grpc, default /api/)

return {
    name = "yar_grpc_bridge",
    fields = {
        {
            config = {
                type = "record",
                fields = {
                    {
                        direction = {
                            type = "string",
                            required = true,
                            one_of = { "grpc2yar", "yar2grpc" },
                            description = "Bridge direction: grpc2yar (gRPC→YAR) or yar2grpc (YAR→gRPC)",
                        },
                    },
                    {
                        services = {
                            type = "map",
                            required = true,
                            keys = { type = "string" },
                            values = {
                                type = "record",
                                fields = {
                                    { proto = { type = "string", required = true } },
                                    { url = { type = "string" } },
                                    { methods = { type = "array", elements = { type = "string" } } },
                                    {
                                        options = {
                                            type = "map",
                                            keys = { type = "string" },
                                            values = { type = "string" },
                                        },
                                    },
                                },
                            },
                        },
                    },
                    {
                        yar_options = {
                            type = "map",
                            keys = { type = "string" },
                            values = { type = "string" },
                        },
                    },
                    {
                        max_payload_bytes = {
                            type = "integer",
                            default = 8388608,
                            between = { 1, 2147483647 },
                        },
                    },
                    {
                        grpc_backend_url = {
                            type = "string",
                            required = function(config)
                                return config.direction == "yar2grpc"
                            end,
                            description = "HTTP bridge URL of the gRPC backend (required for yar2grpc direction)",
                        },
                    },
                    {
                        yar_path_prefix = {
                            type = "string",
                            default = "/api/",
                        },
                    },
                },
            },
        },
    },
}
