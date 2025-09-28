-- /protocols/network_adapter.lua
-- Network adapter that integrates with netd daemon when available
-- Falls back to direct rednet/HTTP when netd is not running

local NetworkAdapter = {}
NetworkAdapter.__index = NetworkAdapter

-- Network types
NetworkAdapter.NETWORK_TYPES = {
    LOCAL = "local",    -- Use rednet for local ComputerCraft network
    REMOTE = "remote",  -- Use HTTP/WebSocket for external connections
    AUTO = "auto"       -- Automatically detect based on URL
}

-- Protocol port mappings (compatible with netd)
NetworkAdapter.PROTOCOL_PORTS = {
    http = 80,
    https = 443,
    ws = 8080,
    wss = 8443,
    tcp = 8888,
    mqtt = 1883,
    ssh = 22,
    ftp = 21,
    webrtc = 9000
}

function NetworkAdapter:new(networkType, options)
    local obj = {}
    setmetatable(obj, self)

    obj.networkType = networkType or NetworkAdapter.NETWORK_TYPES.AUTO
    obj.options = options or {}

    -- Check if netd is running
    obj.netdAvailable = fs.exists("/var/run/netd.pid")
    obj.netLib = nil
    obj.config = nil

    -- Try to load network library if netd is running
    if obj.netdAvailable and fs.exists("/lib/network.lua") then
        local success, lib = pcall(dofile, "/lib/network.lua")
        if success then
            obj.netLib = lib
            obj.useNetd = true

            -- Get configuration from netd
            if obj.netLib.getInfo then
                local info = obj.netLib.getInfo()
                obj.config = {
                    ip = info.ip,
                    mac = info.mac,
                    hostname = info.hostname,
                    fqdn = info.fqdn,
                    gateway = info.gateway,
                    dns = info.dns,
                    modem_available = info.modem_available
                }
            end
        else
            obj.useNetd = false
        end
    else
        obj.useNetd = false

        -- Fall back to standalone configuration
        obj.config = obj:generateStandaloneConfig()
    end

    -- Network state
    obj.connections = {}
    obj.servers = {}
    obj.packetId = 0
    obj.computerId = os.getComputerID()

    -- Initialize network if not using netd
    if not obj.useNetd then
        obj:initializeStandalone()
    end

    return obj
end

-- Generate standalone configuration when netd is not available
function NetworkAdapter:generateStandaloneConfig()
    local id = os.getComputerID()
    local label = os.getComputerLabel() or ""

    -- Generate MAC
    local mac = string.format("CC:AF:%02X:%02X:%02X:%02X",
            bit.band(bit.brshift(id, 24), 0xFF),
            bit.band(bit.brshift(id, 16), 0xFF),
            bit.band(bit.brshift(id, 8), 0xFF),
            bit.band(id, 0xFF))

    -- Generate IP (10.0.X.X subnet)
    local ip = string.format("10.0.%d.%d",
            math.floor(id / 254) % 256,
            (id % 254) + 1)

    -- Generate hostname
    local hostname = label ~= "" and
            string.format("%s-%d", label:lower():gsub("[^%w%-]", ""), id) or
            string.format("cc-%d", id)

    -- Check for modem
    local modem_available = peripheral.find("modem") ~= nil

    return {
        ip = ip,
        mac = mac,
        hostname = hostname,
        fqdn = hostname .. ".local",
        gateway = "10.0.0.1",
        dns = { primary = "10.0.0.1", secondary = "8.8.8.8" },
        modem_available = modem_available
    }
end

-- Initialize standalone mode (when netd is not running)
function NetworkAdapter:initializeStandalone()
    -- Open rednet if needed and modem available
    if self.config.modem_available and not rednet.isOpen() then
        local modem = peripheral.find("modem")
        if modem then
            rednet.open(peripheral.getName(modem))
        end
    end

    -- Register hostname if modem available
    if self.config.modem_available then
        rednet.host("network_adapter", self.config.hostname)
    end
end

-- Determine if URL is local or remote
function NetworkAdapter:isLocalURL(url)
    -- Check for local indicators
    if url:find("%.local") or
            url:find("^localhost") or
            url:find("^127%.") or
            url:find("^10%.0%.") or
            url:find("^192%.168%.") or
            url:find("^172%.") or
            url:find("^cc%-") or
            url:find("^computer%-") then
        return true
    end
    return false
end

-- Parse URL
function NetworkAdapter:parseURL(url)
    local protocol, host, port, path = url:match("^(%w+)://([^:/]+):?(%d*)(/?.*)$")

    if not protocol then
        -- Try without protocol
        host, port, path = url:match("^([^:/]+):?(%d*)(/?.*)$")
        protocol = "http"
    end

    port = tonumber(port) or NetworkAdapter.PROTOCOL_PORTS[protocol] or 80
    path = path ~= "" and path or "/"

    -- Determine if local
    local isLocal = self:isLocalURL(host)

    -- Auto-detect network type
    if self.networkType == NetworkAdapter.NETWORK_TYPES.AUTO then
        self.networkType = isLocal and NetworkAdapter.NETWORK_TYPES.LOCAL or NetworkAdapter.NETWORK_TYPES.REMOTE
    end

    return {
        protocol = protocol,
        host = host,
        port = port,
        path = path,
        isLocal = isLocal,
        url = url
    }
end

-- HTTP GET implementation
function NetworkAdapter:httpGet(url, headers)
    local parsed = self:parseURL(url)

    -- Use netd if available and URL is local
    if self.useNetd and parsed.isLocal and self.netLib then
        return self.netLib.http(url, {
            method = "GET",
            headers = headers
        })
    elseif parsed.isLocal and self.networkType ~= NetworkAdapter.NETWORK_TYPES.REMOTE then
        -- Use standalone local implementation
        return self:localHttpRequest({
            method = "GET",
            url = parsed,
            headers = headers
        })
    else
        -- Use native HTTP for remote
        return self:remoteHttpGet(url, headers)
    end
end

-- HTTP POST implementation
function NetworkAdapter:httpPost(url, data, headers)
    local parsed = self:parseURL(url)

    -- Use netd if available and URL is local
    if self.useNetd and parsed.isLocal and self.netLib then
        return self.netLib.http(url, {
            method = "POST",
            headers = headers,
            body = data
        })
    elseif parsed.isLocal and self.networkType ~= NetworkAdapter.NETWORK_TYPES.REMOTE then
        -- Use standalone local implementation
        return self:localHttpRequest({
            method = "POST",
            url = parsed,
            headers = headers,
            body = data
        })
    else
        -- Use native HTTP for remote
        return self:remoteHttpPost(url, data, headers)
    end
end

-- Generic HTTP request
function NetworkAdapter:httpRequest(options)
    local parsed = self:parseURL(options.url)

    -- Use netd if available and URL is local
    if self.useNetd and parsed.isLocal and self.netLib then
        return self.netLib.http(options.url, options)
    elseif parsed.isLocal and self.networkType ~= NetworkAdapter.NETWORK_TYPES.REMOTE then
        options.url = parsed
        return self:localHttpRequest(options)
    else
        return self:remoteHttpRequest(options)
    end
end

-- WebSocket implementation
function NetworkAdapter:websocket(url)
    local parsed = self:parseURL(url)

    -- Use netd if available and URL is local
    if self.useNetd and parsed.isLocal and self.netLib then
        return self.netLib.websocket(url)
    elseif parsed.isLocal and self.networkType ~= NetworkAdapter.NETWORK_TYPES.REMOTE then
        return self:localWebsocket(parsed)
    else
        return self:remoteWebsocket(url)
    end
end

-- Standalone local HTTP request (when netd is not running)
function NetworkAdapter:localHttpRequest(options)
    if not self.config.modem_available then
        return nil, "No modem available for local network"
    end

    local url = options.url

    -- Ensure modem is open
    if not rednet.isOpen() then
        local modem = peripheral.find("modem")
        if modem then
            rednet.open(peripheral.getName(modem))
        else
            return nil, "No modem found"
        end
    end

    -- Resolve hostname to computer ID
    local destId = self:resolveHostnameStandalone(url.host)
    if not destId then
        return nil, "Host not found"
    end

    -- Create HTTP packet
    self.packetId = self.packetId + 1
    local packet = {
        type = "http_request",
        id = self.packetId,
        method = options.method or "GET",
        protocol = url.protocol,
        host = url.host,
        port = url.port,
        path = url.path,
        headers = options.headers or {},
        body = options.body,
        source = {
            ip = self.config.ip,
            mac = self.config.mac,
            port = math.random(1024, 65535)
        },
        timestamp = os.epoch("utc")
    }

    -- Send packet
    rednet.send(destId, packet, "network_adapter_http")

    -- Wait for response
    local timeout = os.startTimer(options.timeout or 5)
    while true do
        local event, param1, param2, param3 = os.pullEvent()

        if event == "rednet_message" and param3 == "network_adapter_http" then
            local sender, response = param1, param2
            if response.type == "http_response" and response.id == packet.id then
                os.cancelTimer(timeout)
                return self:createHttpResponse(response)
            end
        elseif event == "timer" and param1 == timeout then
            return nil, "Request timeout"
        end
    end
end

-- Standalone WebSocket (when netd is not running)
function NetworkAdapter:localWebsocket(url)
    if not self.config.modem_available then
        return nil, "No modem available for local network"
    end

    -- Ensure modem is open
    if not rednet.isOpen() then
        local modem = peripheral.find("modem")
        if modem then
            rednet.open(peripheral.getName(modem))
        else
            return nil, "No modem found"
        end
    end

    local destId = self:resolveHostnameStandalone(url.host)
    if not destId then
        return nil, "Host not found"
    end

    -- Create WebSocket connection object
    local ws = {
        url = url,
        destId = destId,
        connected = false,
        adapter = self,
        connectionId = os.epoch("utc") .. "_" .. math.random(1000, 9999)
    }

    -- WebSocket methods
    function ws:connect()
        -- Send connect packet
        rednet.send(self.destId, {
            type = "ws_connect",
            connectionId = self.connectionId,
            url = self.url
        }, "network_adapter_ws")

        -- Wait for acceptance
        local timeout = os.startTimer(5)
        while true do
            local event, param1, param2, param3 = os.pullEvent()
            if event == "rednet_message" and param3 == "network_adapter_ws" then
                local sender, msg = param1, param2
                if msg.type == "ws_accept" and msg.connectionId == self.connectionId then
                    os.cancelTimer(timeout)
                    self.connected = true
                    return true
                end
            elseif event == "timer" and param1 == timeout then
                return false, "Connection timeout"
            end
        end
    end

    function ws:send(data)
        if not self.connected then
            return false, "Not connected"
        end

        rednet.send(self.destId, {
            type = "ws_data",
            connectionId = self.connectionId,
            data = data
        }, "network_adapter_ws")
        return true
    end

    function ws:receive(timeout)
        local timer = timeout and os.startTimer(timeout)
        while true do
            local event, param1, param2, param3 = os.pullEvent()
            if event == "rednet_message" and param3 == "network_adapter_ws" then
                local sender, msg = param1, param2
                if msg.type == "ws_data" and msg.connectionId == self.connectionId then
                    if timer then os.cancelTimer(timer) end
                    return msg.data
                end
            elseif event == "timer" and timer and param1 == timer then
                return nil
            end
        end
    end

    function ws:close()
        if self.connected then
            rednet.send(self.destId, {
                type = "ws_close",
                connectionId = self.connectionId
            }, "network_adapter_ws")
            self.connected = false
        end
    end

    -- Auto-connect
    ws:connect()

    return ws
end

-- Resolve hostname in standalone mode
function NetworkAdapter:resolveHostnameStandalone(hostname)
    -- Check for localhost
    if hostname == "localhost" or hostname == "127.0.0.1" then
        return self.computerId
    end

    -- Check for IP address format
    if hostname:match("^%d+%.%d+%.%d+%.%d+$") then
        -- Try to find computer with this IP
        rednet.broadcast({
            type = "ip_query",
            ip = hostname
        }, "network_adapter_discovery")

        local timeout = os.startTimer(2)
        while true do
            local event, param1, param2, param3 = os.pullEvent()
            if event == "rednet_message" and param3 == "network_adapter_discovery" then
                local sender, msg = param1, param2
                if msg.type == "ip_response" and msg.ip == hostname then
                    os.cancelTimer(timeout)
                    return sender
                end
            elseif event == "timer" and param1 == timeout then
                break
            end
        end
    end

    -- Try hostname resolution
    rednet.broadcast({
        type = "hostname_query",
        hostname = hostname
    }, "network_adapter_discovery")

    local timeout = os.startTimer(2)
    while true do
        local event, param1, param2, param3 = os.pullEvent()
        if event == "rednet_message" and param3 == "network_adapter_discovery" then
            local sender, msg = param1, param2
            if msg.type == "hostname_response" and
                    (msg.hostname == hostname or msg.hostname == hostname:gsub("%.local$", "")) then
                os.cancelTimer(timeout)
                return sender
            end
        elseif event == "timer" and param1 == timeout then
            break
        end
    end

    return nil
end

-- Create HTTP response object
function NetworkAdapter:createHttpResponse(packet)
    local response = {
        data = packet.body or "",
        code = packet.code or 200,
        headers = packet.headers or {},

        readAll = function()
            return packet.body or ""
        end,

        getResponseCode = function()
            return packet.code or 200
        end,

        getResponseHeaders = function()
            return packet.headers or {}
        end,

        close = function()
            -- Cleanup
        end
    }

    return response
end

-- Remote implementations (standard HTTP/WebSocket)
function NetworkAdapter:remoteHttpGet(url, headers)
    local c_http = http or _G.http
    if c_http then
        return c_http.get(url, headers)
    else
        return nil, "HTTP API not available"
    end
end

function NetworkAdapter:remoteHttpPost(url, data, headers)
    local c_http = http or _G.http
    if c_http then
        return c_http.post(url, data, headers)
    else
        return nil, "HTTP API not available"
    end
end

function NetworkAdapter:remoteHttpRequest(options)
    local c_http = http or _G.http
    if c_http then
        return c_http.request(options)
    else
        return nil, "HTTP API not available"
    end
end

function NetworkAdapter:remoteWebsocket(url)
    local c_http = http or _G.http
    if c_http and c_http.websocket then
        return c_http.websocket(url)
    else
        return nil, "WebSocket API not available"
    end
end

-- Check if netd is available
function NetworkAdapter:isNetdRunning()
    return self.useNetd
end

-- Get network info
function NetworkAdapter:getNetworkInfo()
    if self.useNetd and self.netLib and self.netLib.getInfo then
        return self.netLib.getInfo()
    else
        return self.config
    end
end

-- Create server (local network only)
function NetworkAdapter:createServer(port, handler)
    if self.useNetd and self.netLib and self.netLib.createServer then
        return self.netLib.createServer(port, handler)
    elseif self.config.modem_available then
        -- Standalone server implementation
        if not rednet.isOpen() then
            local modem = peripheral.find("modem")
            if modem then
                rednet.open(peripheral.getName(modem))
            else
                return nil, "No modem available"
            end
        end

        -- Start server loop
        parallel.waitForAny(function()
            while true do
                local sender, message, protocol = rednet.receive()

                if protocol == "network_adapter_http" then
                    if type(message) == "table" and
                            message.type == "http_request" and
                            message.port == port then

                        -- Handle request
                        local response = handler({
                            method = message.method,
                            path = message.path,
                            headers = message.headers,
                            body = message.body,
                            source = message.source
                        })

                        -- Send response
                        local responsePacket = {
                            type = "http_response",
                            id = message.id,
                            code = response.code or 200,
                            headers = response.headers or {},
                            body = response.body or "",
                            timestamp = os.epoch("utc")
                        }

                        rednet.send(sender, responsePacket, "network_adapter_http")
                    end
                end
            end
        end)

        return true
    else
        return nil, "No network available for server"
    end
end

return NetworkAdapter