-- kong/plugins/yar_grpc_bridge/handler.lua
-- Kong custom plugin: YAR ↔ gRPC protocol bridge.
--
-- Wires Kong's access phase to the bridge's HTTP endpoint modules
-- (grpc2yar_endpoint.serve / yar2grpc_endpoint.handle) from lua-resty-yar-grpc-bridge.
-- Kong runs on OpenResty → ngx.* available → bridge entry modules work as-is.
--
-- Lazy initialization: bridge.setup() / yar2grpc.setup() runs once per worker
-- on first request (Kong's init_worker phase lacks per-plugin config).
--
-- For yar2grpc direction, the handler parses the URI to extract the service name
-- and sets ngx.var.service_name (declared via Kong nginx custom directives).

local bridge = require("resty.yar_grpc_bridge")
local grpc2yar_endpoint = require("resty.yar_grpc_bridge.grpc2yar_endpoint")
local yar2grpc = require("resty.yar_grpc_bridge.yar2grpc")
local yar2grpc_endpoint = require("resty.yar_grpc_bridge.yar2grpc_endpoint")
local errors = require("yar_grpc.errors")

local ngx = ngx
local type = type
local tostring = tostring
local tonumber = tonumber
local pairs = pairs
local ipairs = ipairs
local table_sort = table.sort
local table_concat = table.concat
local math_huge = math.huge

local Plugin = {
    PRIORITY = 750,
    VERSION = "0.1.0",
}

-- Worker-level initialization flag + config fingerprint + last error
local _initialized = false
local _config_sig = nil
local _setup_error = nil

--- Serialize a config table deterministically (sorted keys) for signature comparison.
-- Captures all service config values so that changing proto/url/methods/options
-- triggers re-setup, not just adding/removing service names (CR C1/W1 fix).
local function serialize_table(tbl, depth)
    depth = depth or 0
    if depth > 20 or type(tbl) ~= "table" then
        return tostring(tbl)
    end
    local parts = {}
    local keys = {}
    for k in pairs(tbl) do
        keys[#keys + 1] = k
    end
    table_sort(keys)
    for _, k in ipairs(keys) do
        local v = tbl[k]
        if type(v) == "table" then
            parts[#parts + 1] = k .. "=" .. serialize_table(v, depth + 1)
        else
            parts[#parts + 1] = k .. "=" .. tostring(v)
        end
    end
    return "{" .. table_concat(parts, ",") .. "}"
end

--- Build a signature string from the config to detect config changes.
-- Includes direction, services (with all values), yar_options, max_payload_bytes,
-- and grpc_backend_url — so any meaningful config change triggers re-setup.
local function config_signature(conf)
    local parts = {}
    parts[#parts + 1] = conf.direction or ""
    parts[#parts + 1] = tostring(conf.max_payload_bytes or "")
    parts[#parts + 1] = conf.grpc_backend_url or ""
    parts[#parts + 1] = conf.yar_path_prefix or ""
    if conf.services then
        parts[#parts + 1] = serialize_table(conf.services)
    end
    if conf.yar_options then
        parts[#parts + 1] = serialize_table(conf.yar_options)
    end
    return table_concat(parts, "||")
end

--- Recursively coerce string values to appropriate Lua types
-- Kong declarative config (YAML) may deliver numbers as strings depending on schema.
local function coerce_values(tbl, depth)
    depth = depth or 0
    if depth > 20 or type(tbl) ~= "table" then
        return tbl
    end
    local result = {}
    for k, v in pairs(tbl) do
        if type(v) == "string" then
            local num = tonumber(v)
            -- Exclude inf/nan (tonumber("inf") returns inf) — CR I1 fix
            if
                num
                and tostring(num) == v
                and num == num -- NaN check (NaN ~= NaN)
                and num ~= math_huge
                and num ~= -math_huge
            then
                result[k] = num
            elseif v == "true" then
                result[k] = true
            elseif v == "false" then
                result[k] = false
            else
                result[k] = v
            end
        elseif type(v) == "table" then
            result[k] = coerce_values(v, depth + 1)
        else
            result[k] = v
        end
    end
    return result
end

--- One-time per-worker setup: load .pb, inject cosocket, configure services.
-- Wrapped in pcall — setup errors are captured and returned so the access
-- handler can send a clean HTTP 500 instead of an unhandled exception (CR C2 fix).
local function ensure_setup(conf)
    local sig = config_signature(conf)
    if _initialized and sig == _config_sig then
        return true
    end

    local ok, err = pcall(function()
        if conf.direction == "grpc2yar" then
            bridge.setup {
                services = coerce_values(conf.services),
                yar_options = conf.yar_options and coerce_values(conf.yar_options) or {},
                max_payload_bytes = conf.max_payload_bytes,
            }
        else
            -- yar2grpc: load .pb descriptors, clear converter caches, inject transport
            local services = coerce_values(conf.services)

            -- Lazy require: pb / grpc_converter / pb_converter only available in runtime
            -- (lua-yar-grpc installed via luarocks), not in unit test env
            local pb = require("pb")
            local grpc_converter = require("yar_grpc.grpc_converter")
            local pb_converter = require("yar_grpc.pb_converter")

            -- Clear converter caches (supports re-init: proto reload, hot config changes)
            grpc_converter.clear_cache()
            pb_converter.clear_cache()

            -- Load .pb files (dedup: same file loaded only once)
            local loaded_files = {}
            for _, svc in pairs(services) do
                local proto_file = svc.proto
                if proto_file and not loaded_files[proto_file] then
                    local f, ferr = io.open(proto_file, "rb")
                    if not f then
                        error(
                            "yar_grpc_bridge: cannot open proto file: " .. proto_file .. " (" .. tostring(ferr) .. ")",
                            0
                        )
                    end
                    local data = f:read("*a")
                    f:close()
                    if not data or #data == 0 then
                        error("yar_grpc_bridge: empty proto file: " .. proto_file, 0)
                    end
                    local pok, res, offset = pcall(pb.load, data)
                    if not pok then
                        error("yar_grpc_bridge: failed to load " .. proto_file .. ": " .. tostring(res), 0)
                    end
                    if res == false then
                        error(
                            "yar_grpc_bridge: invalid .pb descriptor "
                                .. proto_file
                                .. " (parse error at offset "
                                .. tostring(offset)
                                .. ")",
                            0
                        )
                    end
                    loaded_files[proto_file] = true
                end
            end

            -- Build grpc_transport using lua-resty-http
            local backend_url = conf.grpc_backend_url
            local transport
            if backend_url then
                local http_new = require("resty.http").new
                transport = function(service, method, frame)
                    local httpc = http_new()
                    local res, req_err = httpc:request_uri(backend_url .. "/" .. service .. "/" .. method, {
                        method = "POST",
                        body = frame,
                        headers = {
                            ["Content-Type"] = "application/grpc",
                            ["TE"] = "trailers",
                        },
                    })
                    if not res then
                        return nil, errors.UNAVAILABLE, "gRPC backend error: " .. tostring(req_err)
                    end
                    if res.status ~= 200 then
                        return nil, errors.UNAVAILABLE, "gRPC backend HTTP error: " .. tostring(res.status)
                    end
                    local grpc_status = tonumber(res.headers["grpc-status"]) or 0
                    if grpc_status ~= 0 then
                        return nil, grpc_status, res.headers["grpc-message"] or "gRPC error"
                    end
                    return res.body
                end
            end

            yar2grpc.setup {
                services = services,
                grpc_transport = transport,
            }
        end
    end)

    if not ok then
        _setup_error = tostring(err)
        return nil, _setup_error
    end

    _initialized = true
    _config_sig = sig
    _setup_error = nil
    return true
end

--- Kong access phase handler
-- Delegates to the bridge endpoint module based on conf.direction.
-- The endpoint module calls ngx.exit(), short-circuiting Kong's upstream proxying.
function Plugin:access(conf)
    local ok, err = ensure_setup(conf)
    if not ok then
        ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
        ngx.header["Content-Type"] = "text/plain"
        ngx.say("yar_grpc_bridge plugin setup failed: " .. tostring(err))
        return
    end

    if conf.direction == "grpc2yar" then
        -- grpc2yar: endpoint reads ngx.var.uri, ngx.req.get_body_data, etc.
        -- All available in Kong's access phase. No variable injection needed.
        grpc2yar_endpoint.serve()
        return
    end

    -- yar2grpc: parse service name from URI and set ngx.var.service_name
    -- (variable declared via Kong nginx custom directive: set $service_name "";)
    local uri = ngx.var.uri or ""
    local prefix = conf.yar_path_prefix or "/api/"
    local service_name

    if uri:sub(1, #prefix) == prefix then
        -- Strip prefix: /api/calculator.Calculator → calculator.Calculator
        service_name = uri:sub(#prefix + 1)
        -- Remove trailing path segments if any
        local slash = service_name:find("/")
        if slash then
            service_name = service_name:sub(1, slash - 1)
        end
    else
        -- Fallback: strip leading slashes, take first path segment (CR W4 fix)
        local path = uri:gsub("^/+", "")
        if path ~= "" then
            local slash = path:find("/")
            service_name = slash and path:sub(1, slash - 1) or path
        end
    end

    if service_name and service_name ~= "" then
        ngx.var.service_name = service_name
    end

    yar2grpc_endpoint.handle()
end

return Plugin
