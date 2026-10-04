-- t/00-unit/handler_spec.lua
-- BDD unit tests for the Kong yar_grpc_bridge plugin handler.
--
-- Tests the handler logic (config signature, value coercion, direction routing,
-- URI parsing for yar2grpc) using mocks — no real network or nginx needed.
--
-- Run: busted t/00-unit/handler_spec.lua

local assert = require("luassert")
local say = require("say")

-- ── Mock infrastructure ──
-- We mock ngx.*, bridge entry modules, and Kong PDK so the handler runs
-- in isolation. The handler's core logic (setup, routing, URI parsing)
-- is testable without OpenResty.

-- Declare first so say/exit closures capture the local upvalue (not a global)
local mock_ngx
mock_ngx = {
    var = {},
    req = {},
    header = {},
    ctx = {},
    HTTP_OK = 200,
    HTTP_BAD_REQUEST = 400,
    HTTP_NOT_FOUND = 404,
    HTTP_INTERNAL_SERVER_ERROR = 500,
    INFO = 5,
    WARN = 6,
    ERR = 8,
    escape_uri = function(s) return s end,
    say = function(msg) mock_ngx._said = msg end,
    exit = function(code) mock_ngx._exited = code; return true end,
}

-- Save original ngx if present
local saved_ngx = _G.ngx

-- Mock yar_grpc.errors (gRPC status codes, used by handler for UNAVAILABLE)
package.loaded["yar_grpc.errors"] = {
    OK = 0,
    UNAVAILABLE = 14,
    INVALID_ARGUMENT = 3,
    NOT_FOUND = 5,
    INTERNAL = 13,
    DEADLINE_EXCEEDED = 4,
    RESOURCE_EXHAUSTED = 8,
    UNIMPLEMENTED = 12,
}

-- Mock pb / grpc_converter / pb_converter (lazy required by ensure_setup for yar2grpc)
package.loaded["pb"] = { load = function() return true end }
package.loaded["yar_grpc.grpc_converter"] = { clear_cache = function() end }
package.loaded["yar_grpc.pb_converter"] = { clear_cache = function() end }

-- Mock bridge modules
local bridge_setup_called = false
local bridge_setup_args = nil
local yar2grpc_setup_called = false
local yar2grpc_setup_args = nil
local grpc2yar_serve_called = false
local yar2grpc_handle_called = false
local proto_open_fail = false

package.loaded["resty.yar_grpc_bridge"] = {
    setup = function(opts)
        bridge_setup_called = true
        bridge_setup_args = opts
    end,
    get_max_payload_bytes = function() return 8388608 end,
    resolve_service_config = function() return nil, nil end,
    serve = function() end,
    log_phase = function() end,
}
package.loaded["resty.yar_grpc_bridge.grpc2yar_endpoint"] = {
    serve = function()
        grpc2yar_serve_called = true
    end,
}
package.loaded["resty.yar_grpc_bridge.yar2grpc"] = {
    setup = function(opts)
        yar2grpc_setup_called = true
        yar2grpc_setup_args = opts
    end,
    has_transport = function() return true end,
    get_proxy = function() return nil end,
    handle = function() end,
}
package.loaded["resty.yar_grpc_bridge.yar2grpc_endpoint"] = {
    handle = function()
        yar2grpc_handle_called = true
    end,
}

-- Mock lua-resty-http (response configurable per-test via http_response / http_request_error)
local http_response = { status = 200, body = "mock-frame", headers = { ["grpc-status"] = "0" } }
local http_request_error = false -- when true, request_uri returns nil (connection failure)
package.loaded["resty.http"] = {
    new = function()
        return {
            request_uri = function(self, url, opts)
                if http_request_error then
                    return nil, "connection refused"
                end
                return http_response
            end,
        }
    end,
}

-- Helper: reset all call flags before each test
local function reset()
    bridge_setup_called = false
    bridge_setup_args = nil
    yar2grpc_setup_called = false
    yar2grpc_setup_args = nil
    grpc2yar_serve_called = false
    yar2grpc_handle_called = false
    proto_open_fail = false
    mock_ngx.var = {}
    mock_ngx.req = {}
    mock_ngx.header = {}
    mock_ngx.ctx = {}
    mock_ngx._said = nil
    mock_ngx._exited = nil
    http_response.status = 200
    http_response.body = "mock-frame"
    http_response.headers = { ["grpc-status"] = "0" }
    http_request_error = false
end

describe("yar_grpc_bridge plugin handler", function()
    local handler

    -- Save real io.open (restored in after_each)
    local real_io_open = io.open

    before_each(function()
        reset()
        _G.ngx = mock_ngx
        -- Mock io.open for .pb files (proto loading in ensure_setup)
        -- proto_open_fail: when true, .pb open fails (used by error-path tests)
        io.open = function(path, mode)
            if path and path:match("%.pb$") then
                if proto_open_fail then
                    return nil, "mock: proto open failed"
                end
                return { read = function() return "mock-pb-data" end, close = function() end }
            end
            return real_io_open(path, mode)
        end
        -- Force re-require the handler so it picks up fresh mocks
        package.loaded["kong.plugins.yar_grpc_bridge.handler"] = nil
        handler = require("kong.plugins.yar_grpc_bridge.handler")
    end)

    after_each(function()
        _G.ngx = saved_ngx
        io.open = real_io_open
    end)

    describe("Plugin table", function()
        it("has PRIORITY and VERSION", function()
            assert.is_number(handler.PRIORITY)
            assert.is_string(handler.VERSION)
        end)
    end)

    describe("grpc2yar direction", function()
        local conf = {
            direction = "grpc2yar",
            services = {
                ["calculator.Calculator"] = {
                    proto = "/etc/kong/proto/calc.pb",
                    url = "http://php-yar:8888/api.php",
                    options = { timeout = "5000", packager = "json" },
                },
            },
            yar_options = { timeout = "3000" },
            max_payload_bytes = 4194304,
        }

        it("calls bridge.setup on first access", function()
            handler:access(conf)
            assert.is_true(bridge_setup_called)
            assert.is_not_nil(bridge_setup_args)
            assert.are.equal("calculator.Calculator", next(bridge_setup_args.services))
        end)

        it("coerces string option values to numbers", function()
            handler:access(conf)
            local _, svc_opts = next(bridge_setup_args.services)
            -- options.timeout should be coerced from "5000" to 5000
            assert.are.equal(5000, svc_opts.options.timeout)
            -- packager stays a string
            assert.are.equal("json", svc_opts.options.packager)
        end)

        it("coerces yar_options values", function()
            handler:access(conf)
            assert.are.equal(3000, bridge_setup_args.yar_options.timeout)
        end)

        it("passes max_payload_bytes", function()
            handler:access(conf)
            assert.are.equal(4194304, bridge_setup_args.max_payload_bytes)
        end)

        it("delegates to grpc2yar_endpoint.serve()", function()
            handler:access(conf)
            assert.is_true(grpc2yar_serve_called)
        end)

        it("does not call yar2grpc setup on subsequent calls", function()
            handler:access(conf)
            -- Second call: setup should not be called again (same config)
            reset()
            handler:access(conf)
            assert.is_false(bridge_setup_called)
        end)
    end)

    describe("yar2grpc direction", function()
        local conf = {
            direction = "yar2grpc",
            services = {
                ["calculator.Calculator"] = {
                    proto = "/etc/kong/proto/calc.pb",
                    methods = { "Add", "Subtract" },
                },
            },
            grpc_backend_url = "http://go-grpc:50052",
            yar_path_prefix = "/api/",
        }

        it("calls yar2grpc.setup with transport on first access", function()
            handler:access(conf)
            assert.is_true(yar2grpc_setup_called)
            assert.is_not_nil(yar2grpc_setup_args.grpc_transport)
            assert.are.equal("function", type(yar2grpc_setup_args.grpc_transport))
        end)

        it("delegates to yar2grpc_endpoint.handle()", function()
            -- Set up var.uri and var.service_name
            mock_ngx.var.uri = "/api/calculator.Calculator"
            handler:access(conf)
            assert.is_true(yar2grpc_handle_called)
        end)

        it("parses service name from URI with prefix", function()
            mock_ngx.var.uri = "/api/calculator.Calculator"
            handler:access(conf)
            assert.are.equal("calculator.Calculator", mock_ngx.var.service_name)
        end)

        it("parses service name with trailing path segment", function()
            mock_ngx.var.uri = "/api/calculator.Calculator/Add"
            handler:access(conf)
            assert.are.equal("calculator.Calculator", mock_ngx.var.service_name)
        end)

        it("handles custom prefix", function()
            local conf2 = {
                direction = "yar2grpc",
                services = conf.services,
                grpc_backend_url = "http://go-grpc:50052",
                yar_path_prefix = "/rpc/",
            }
            mock_ngx.var.uri = "/rpc/calculator.Calculator"
            handler:access(conf2)
            assert.are.equal("calculator.Calculator", mock_ngx.var.service_name)
        end)
    end)

    describe("config change detection", function()
        it("re-runs setup when direction changes", function()
            local conf1 = {
                direction = "grpc2yar",
                services = { ["svc.A"] = { proto = "a.pb", url = "http://a" } },
            }
            local conf2 = {
                direction = "yar2grpc",
                services = { ["svc.A"] = { proto = "a.pb", methods = { "M" } } },
                grpc_backend_url = "http://grpc",
            }

            handler:access(conf1)
            assert.is_true(bridge_setup_called)

            reset()
            handler:access(conf2)
            assert.is_true(yar2grpc_setup_called)
        end)

        it("re-runs setup when service list changes", function()
            local conf1 = {
                direction = "grpc2yar",
                services = { ["svc.A"] = { proto = "a.pb", url = "http://a" } },
            }
            local conf2 = {
                direction = "grpc2yar",
                services = { ["svc.B"] = { proto = "b.pb", url = "http://b" } },
            }

            handler:access(conf1)
            reset()
            handler:access(conf2)
            assert.is_true(bridge_setup_called)
        end)
    end)

    describe("grpc_transport (yar2grpc)", function()
        it("builds a transport that calls gRPC backend via HTTP", function()
            local conf = {
                direction = "yar2grpc",
                services = { ["svc.A"] = { proto = "a.pb", methods = { "M" } } },
                grpc_backend_url = "http://go:50052",
            }
            handler:access(conf)
            local transport = yar2grpc_setup_args.grpc_transport

            local payload, status, err = transport("svc.A", "M", "frame-bytes")
            assert.are.equal("mock-frame", payload)
            assert.is_nil(status)
            assert.is_nil(err)
        end)
    end)

    describe("error paths", function()
        it("returns HTTP 500 + ngx.exit on setup failure (proto open error)", function()
            proto_open_fail = true
            local conf = {
                direction = "yar2grpc",
                services = { ["svc.A"] = { proto = "/bad.pb", methods = { "M" } } },
                grpc_backend_url = "http://go:50052",
            }
            handler:access(conf)
            assert.are.equal(mock_ngx.HTTP_INTERNAL_SERVER_ERROR, mock_ngx.status)
            assert.truthy(mock_ngx._said)
            assert.are.equal(mock_ngx.HTTP_INTERNAL_SERVER_ERROR, mock_ngx._exited)
            assert.is_false(yar2grpc_setup_called)
        end)

        it("transport returns UNAVAILABLE on non-200 backend status", function()
            http_response.status = 502
            local conf = {
                direction = "yar2grpc",
                services = { ["svc.A"] = { proto = "a.pb", methods = { "M" } } },
                grpc_backend_url = "http://go:50052",
            }
            handler:access(conf)
            local transport = yar2grpc_setup_args.grpc_transport
            local payload, status, err = transport("svc.A", "M", "frame")
            assert.is_nil(payload)
            assert.are.equal(14, status) -- errors.UNAVAILABLE
            assert.truthy(err)
        end)

        it("transport returns gRPC status + message on non-zero grpc-status", function()
            http_response.headers = { ["grpc-status"] = "7", ["grpc-message"] = "boom" }
            local conf = {
                direction = "yar2grpc",
                services = { ["svc.A"] = { proto = "a.pb", methods = { "M" } } },
                grpc_backend_url = "http://go:50052",
            }
            handler:access(conf)
            local transport = yar2grpc_setup_args.grpc_transport
            local payload, status, err = transport("svc.A", "M", "frame")
            assert.is_nil(payload)
            assert.are.equal(7, status)
            assert.are.equal("boom", err)
        end)

        it("transport returns UNAVAILABLE when request_uri fails (connection)", function()
            http_request_error = true
            local conf = {
                direction = "yar2grpc",
                services = { ["svc.A"] = { proto = "a.pb", methods = { "M" } } },
                grpc_backend_url = "http://go:50052",
            }
            handler:access(conf)
            local transport = yar2grpc_setup_args.grpc_transport
            local payload, status, err = transport("svc.A", "M", "frame")
            assert.is_nil(payload)
            assert.are.equal(14, status) -- errors.UNAVAILABLE
            assert.truthy(err)
        end)
    end)

    describe("coerce_values edge cases", function()
        it("coerces 'true'/'false' strings to booleans", function()
            local conf = {
                direction = "grpc2yar",
                services = {
                    ["svc.A"] = {
                        proto = "a.pb",
                        url = "http://a",
                        options = { flag = "true", disabled = "false" },
                    },
                },
            }
            handler:access(conf)
            local _, svc_opts = next(bridge_setup_args.services)
            assert.is_true(svc_opts.options.flag)
            assert.is_false(svc_opts.options.disabled)
        end)
    end)
end)
