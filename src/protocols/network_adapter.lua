-- /protocols/network_adapter.lua
-- Network adapter with UDP support that integrates with netd daemon
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
    udp = 0,        -- 0 = auto-assign
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
    obj.udpLib = nil

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
                    modem_available = info.modem_available,
                    udp_enabled = info.udp_enabled
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

    -- Try to load UDP protocol if available
    if fs.exists("/protocols/udp.lua") then
        local success, udp = pcall(dofile, "/protocols/udp.lua")
        if success then
            obj.udpLib = udp
        end
    end

    -- Network state
    obj.connections = {}
    obj.servers = {}
    obj.udpSockets = {}
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

    -- Generate IP (10.0.x.x range)
    local ip = string.format("10.0.%d.%d",
            math.floor(id / 254) % 256,
            (id % 254) + 1)

    -- Generate hostname
    local hostname = label ~= "" and
            (label:lower():gsub("[^%w%-]", "") .. "-" .. id) or
            ("cc-" .. id)

    return {
        ip = ip,
        mac = mac,
        hostname = hostname,
        fqdn = hostname .. ".local",
        gateway = "10.0.0.1",
        dns = {"10.0.0.1", "8.8.8.8"},
        modem_available = peripheral.find("modem") ~= nil,
        udp_enabled = self.udpLib ~= nil
    }
end

-- Initialize standalone mode
function NetworkAdapter:initializeStandalone()
    -- Open modem if available
    local modem = peripheral.find("modem")
    if modem then
        local side = peripheral.getName(modem)
        if not rednet.isOpen(side) then
            rednet.open(side)
        end
    end

    -- Initialize UDP if available
    if self.udpLib then
        self.udpLib.start()
    end
end

-- Parse URL to determine if local or remote
function NetworkAdapter:parseURL(url)
    local protocol, host, port, path

    -- Parse protocol://host:port/path
    protocol = url:match("^(%w+)://")
    if protocol then
        host, port, path = url:match("^%w+://([^:/]+):?(%d*)(/?.*)$")
    else
        host, port, path = url:match("^([^:/]+):?(%d*)(/?.*)$")
    end

    -- Default ports based on protocol
    if not port or port == "" then
        port = NetworkAdapter.PROTOCOL_PORTS[protocol] or 80
    else
        port = tonumber(port)
    end

    path = path ~= "" and path or "/"

    -- Determine if local or remote
    local isLocal = false
    if host == "localhost" or
            host == self.config.hostname or
            host == self.config.fqdn or
            host:match("^10%.") or
            host:match("^192%.168%.") or
            host:match("^172%.(%d+)%.") then
        isLocal = true
    end

    return {
        protocol = protocol,
        host = host,
        port = port,
        path = path,
        isLocal = isLocal
    }
end

-- UDP implementation
function NetworkAdapter:udp()
    if self.useNetd and self.netLib and self.netLib.udpSocket then
        -- Use netd's UDP implementation
        return self.netLib
    elseif self.udpLib then
        -- Use standalone UDP
        return self.udpLib
    else
        error("UDP protocol not available")
    end
end

-- Create UDP socket
function NetworkAdapter:udpSocket(port, options)
    if self.useNetd and self.netLib and self.netLib.udpSocket then
        return self.netLib.udpSocket(port, options)
    elseif self.udpLib then
        local socket = self.udpLib.socket(port, options)
        self.udpSockets[socket.port] = socket
        return socket
    else
        return nil, "UDP not available"
    end
end

-- Send UDP datagram
function NetworkAdapter:udpSend(destIP, destPort, data, sourcePort)
    if self.useNetd and self.netLib and self.netLib.udpSend then
        return self.netLib.udpSend(destIP, destPort, data, sourcePort)
    elseif self.udpLib then
        local socket = sourcePort and self.udpSockets[sourcePort]
        if not socket then
            socket = self.udpLib.socket(sourcePort)
            if sourcePort then
                socket:bind(sourcePort)
            end
        end

        local success, err = socket:send(data, destIP, destPort)

        -- Clean up temporary socket
        if not sourcePort or not self.udpSockets[sourcePort] then
            socket:close()
        end

        return success, err
    else
        return nil, "UDP not available"
    end
end

-- Listen for UDP datagrams
function NetworkAdapter:udpListen(port, callback)
    if self.useNetd and self.netLib and self.netLib.udpListen then
        return self.netLib.udpListen(port, callback)
    elseif self.udpLib then
        local socket = self.udpLib.socket(port)
        socket:bind(port)

        if callback then
            socket:setReceiveCallback(callback)
        end

        self.udpSockets[port] = socket
        return socket
    else
        return nil, "UDP not available"
    end
end

-- HTTP implementation (existing)
function NetworkAdapter:http(options)
    if type(options) == "string" then
        options = {url = options}
    end

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

-- WebSocket implementation (existing)
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

-- TCP implementation
function NetworkAdapter:tcp(host, port, options)
    -- Check if we have TCP protocol available
    local tcpLib = nil
    if fs.exists("/protocols/tcp.lua") then
        tcpLib = dofile("/protocols/tcp.lua")
    end

    if not tcpLib then
        return nil, "TCP protocol not available"
    end

    -- Determine if local or remote
    local isLocal = host == "localhost" or
            host == self.config.hostname or
            host:match("^10%.") or
            host:match("^192%.168%.")

    if isLocal and self.config.modem_available then
        -- Local TCP over rednet
        return tcpLib:new(host, port, options)
    else
        -- TCP over external network would need special handling
        return nil, "External TCP connections not supported"
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
            local sender, message = param1, param2
            if type(message) == "table" and message.id == packet.id then
                os.cancelTimer(timeout)
                return {
                    getResponseCode = function() return message.code or 200 end,
                    readAll = function() return message.body or "" end,
                    close = function() end
                }
            end
        elseif event == "timer" and param1 == timeout then
            return nil, "Request timeout"
        end
    end
end

-- Remote HTTP request (external)
function NetworkAdapter:remoteHttpRequest(options)
    local url = type(options) == "string" and options or options.url
    local method = type(options) == "table" and options.method or "GET"
    local headers = type(options) == "table" and options.headers or {}
    local body = type(options) == "table" and options.body

    if method == "POST" then
        return http.post(url, body, headers)
    else
        return http.get(url, headers)
    end
end

-- Standalone WebSocket
function NetworkAdapter:localWebsocket(parsed)
    if not self.config.modem_available then
        return nil, "No modem available"
    end

    -- Implementation similar to network.lua's WebSocket
    local connectionId = "ws_" .. os.epoch("utc") .. "_" .. math.random(1000)

    -- Send connection request
    rednet.broadcast({
        type = "ws_connect",
        connectionId = connectionId,
        url = parsed
    }, "network_adapter_ws")

    -- Wait for response
    local timeout = os.startTimer(5)
    while true do
        local event, param1, param2, param3 = os.pullEvent()

        if event == "rednet_message" and param3 == "network_adapter_ws" then
            local sender, message = param1, param2
            if type(message) == "table" and message.connectionId == connectionId then
                if message.type == "accept" then
                    os.cancelTimer(timeout)
                    -- Return WebSocket object
                    return self:createWebSocketObject(connectionId, sender)
                elseif message.type == "reject" then
                    os.cancelTimer(timeout)
                    return nil, message.reason or "Connection rejected"
                end
            end
        elseif event == "timer" and param1 == timeout then
            return nil, "Connection timeout"
        end
    end
end

-- Remote WebSocket
function NetworkAdapter:remoteWebsocket(url)
    return http.websocket(url)
end

-- Create WebSocket object
function NetworkAdapter:createWebSocketObject(connectionId, peerId)
    return {
        send = function(data)
            rednet.send(peerId, {
                type = "ws_data",
                connectionId = connectionId,
                data = data
            }, "network_adapter_ws")
        end,

        receive = function(timeout)
            local timer = nil
            if timeout then timer = os.startTimer(timeout) end

            while true do
                local event, param1, param2, param3 = os.pullEvent()
                if event == "rednet_message" and param3 == "network_adapter_ws" then
                    local sender, message = param1, param2
                    if sender == peerId and type(message) == "table" and
                            message.connectionId == connectionId and message.type == "ws_data" then
                        if timer then os.cancelTimer(timer) end
                        return message.data
                    end
                elseif event == "timer" and timer and param1 == timer then
                    return nil, "Timeout"
                end
            end
        end,

        close = function()
            rednet.send(peerId, {
                type = "ws_close",
                connectionId = connectionId
            }, "network_adapter_ws")
        end
    }
end

-- Hostname resolution helper
function NetworkAdapter:resolveHostnameStandalone(hostname)
    -- Check if it's already a computer ID
    local id = tonumber(hostname)
    if id then return id end

    -- Try rednet lookup
    local id = rednet.lookup("network_adapter_discovery", hostname)
    if id then return id end

    -- Broadcast query
    rednet.broadcast({
        type = "hostname_query",
        hostname = hostname
    }, "network_adapter_discovery")

    -- Wait for response
    local timeout = os.startTimer(2)
    while true do
        local event, param1, param2, param3 = os.pullEvent()

        if event == "rednet_message" and param3 == "network_adapter_discovery" then
            local sender, message = param1, param2
            if type(message) == "table" and message.type == "hostname_response" and
                    message.hostname == hostname then
                os.cancelTimer(timeout)
                return sender
            end
        elseif event == "timer" and param1 == timeout then
            return nil
        end
    end
end

-- Get network statistics
function NetworkAdapter:getStatistics()
    local stats = {
        connections = 0,
        servers = 0,
        udp_sockets = 0,
        packets_sent = self.packetId,
        netd_running = self.netdAvailable,
        udp_enabled = self.udpLib ~= nil or (self.config and self.config.udp_enabled)
    }

    for _ in pairs(self.connections) do
        stats.connections = stats.connections + 1
    end

    for _ in pairs(self.servers) do
        stats.servers = stats.servers + 1
    end

    for _ in pairs(self.udpSockets) do
        stats.udp_sockets = stats.udp_sockets + 1
    end

    -- Get UDP statistics if available
    if self.udpLib and self.udpLib.getStatistics then
        stats.udp = self.udpLib.getStatistics()
    elseif self.netLib and self.netLib.getUDPStats then
        stats.udp = self.netLib.getUDPStats()
    end

    return stats
end

-- Cleanup
function NetworkAdapter:cleanup()
    -- Close all UDP sockets
    for port, socket in pairs(self.udpSockets) do
        if socket.close then
            socket:close()
        end
    end
    self.udpSockets = {}

    -- Close all connections
    for id, conn in pairs(self.connections) do
        if conn.close then
            conn:close()
        end
    end
    self.connections = {}

    -- Stop all servers
    for id, server in pairs(self.servers) do
        if server.stop then
            server:stop()
        end
    end
    self.servers = {}
end

return NetworkAdapter