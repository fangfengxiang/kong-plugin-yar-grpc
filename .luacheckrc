-- .luacheckrc — luacheck configuration for kong-plugin-yar-grpc
-- Kong/OpenResty globals provided at runtime (ngx, kong PDK)
globals = {"ngx", "kong"}
-- Ignore 'self' in Kong plugin method definitions (Plugin:access, etc.)
ignore = {"self"}
-- Match stylua column_width
max_line_length = 120
