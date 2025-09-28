-- protocols/protocol_names.lua
local Logger = require("util.logger")

-- Create logger for protocol names module
local logger = Logger and Logger:new({
    title = "Protocol Names",
    logFile = "logs/protocol_names.log",
    maxLogs = 100
}) or nil

local PROTOCOL_NAMES = {
    WEBSOCKET = "WebSocket",
    websocket = "websocket",
    HTTP = "HTTP",
    http = "http",
    HTTPS = "HTTPS",
    https = "https",
    WEBRTC = "WebRTC",
    webrtc = "webrtc",
    TCP = "TCP",
    tcp = "tcp",
    MQTT = "MQTT",
    mqtt = "mqtt",
    FTP = "FTP",
    ftp = "ftp",
    SSH = "SSH",
    ssh = "ssh"
}

-- Add metatable for case-insensitive access
setmetatable(PROTOCOL_NAMES, {
    __index = function(t, k)
        local upper = rawget(t, string.upper(k))
        if upper then
            if logger then logger:trace("Protocol name accessed (upper): %s -> %s", k, upper) end
            return upper
        end
        local lower = rawget(t, string.lower(k))
        if lower then
            if logger then logger:trace("Protocol name accessed (lower): %s -> %s", k, lower) end
            return lower
        end
        local value = rawget(t, k)
        if value and logger then
            logger:trace("Protocol name accessed (exact): %s -> %s", k, value)
        elseif logger then
            logger:warn("Protocol name not found: %s", k)
        end
        return value
    end
})

if logger then
    logger:info("Protocol names module loaded with %d protocols", 8)
end

return PROTOCOL_NAMES