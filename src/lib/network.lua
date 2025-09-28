-- /lib/network.lua
-- Network library for interacting with netd (with UDP support)
-- Provides high-level network functions for applications

local network = {}

-- Cache configuration
local cfg = nil
local cfg_loaded = false
local modem_available = false
local active_servers = {}  -- Store server handlers in memory
local udp_sockets = {}  -- Track UDP sockets

-- Load configuration
local function loadConfig()
    if cfg_loaded then
        return cfg
    end

    -- Try to load from main config
    local config_path = "/config/network.cfg"
    if fs.exists(config_path) then
        local file = fs.open(config_path, "r")
        local content = file.readAll()
        file.close()

        local func, err = loadstring(content)
        if func then
            cfg = func()
            cfg_loaded = true

            -- Check if modem is available
            local info_path = "/var/run/network.info"
            if fs.exists(info_path) then
                local info_file = fs.open(info_path, "r")
                local info_data = info_file.readAll()
                info_file.close()
                local info = textutils.unserialize(info_data)
                if info and info.modem_available ~= nil then
                    modem_available = info.modem_available
                end
                -- Check if UDP is enabled
                if info and info.udp_enabled then
                    network.udp_enabled = true
                end
            end

            return cfg
        end
    end

    -- Try to load from network.info if netd is running
    local info_path = "/var/run/network.info"
    if fs.exists(info_path) then
        local file = fs.open(info_path, "r")
        if file then
            local data = file.readAll()
            file.close()
            local info = textutils.unserialize(data)
            if info then
                -- Create minimal config from info
                cfg = {
                    ipv4 = info.ip,
                    mac = info.mac,
                    hostname = info.hostname,
                    fqdn = info.fqdn,
                    gateway = info.gateway,
                    dns = info.dns,
                    id = os.getComputerID(),
                    proto = "ccnet",
                    discovery_proto = "ccnet_discovery",
                    dns_proto = "ccnet_dns",
                    arp_proto = "ccnet_arp",
                    http_proto = "ccnet_http",
                    ws_proto = "ccnet_ws",
                    udp_proto = "ccnet_udp"
                }
                modem_available = info.modem_available or false
                network.udp_enabled = info.udp_enabled or false
                cfg_loaded = true
                return cfg
            end
        end
    end

    error("Network configuration not found. Is netd running?")
end

local function ensureModemOpen()
    if not modem_available then return false end

    local modem = peripheral.find("modem")
    if modem and not rednet.isOpen(peripheral.getName(modem)) then
        rednet.open(peripheral.getName(modem))
    end
    return modem ~= nil
end

-- Check if daemon is running
function network.isDaemonRunning()
    return fs.exists("/var/run/netd.pid")
end

-- Get network info
function network.getInfo()
    if not cfg then loadConfig() end

    -- Read fresh info from netd
    local info_path = "/var/run/network.info"
    if fs.exists(info_path) then
        local file = fs.open(info_path, "r")
        local data = file.readAll()
        file.close()
        local info = textutils.unserialize(data)
        if info then
            return {
                ip = info.ip or cfg.ipv4,
                mac = info.mac or cfg.mac,
                hostname = info.hostname or cfg.hostname,
                fqdn = info.fqdn or cfg.fqdn,
                gateway = info.gateway or cfg.gateway,
                dns = info.dns or cfg.dns,
                modem_available = info.modem_available,
                computer_id = os.getComputerID(),
                udp_enabled = info.udp_enabled or false
            }
        end
    end

    -- Fallback to config
    return {
        ip = cfg.ipv4,
        mac = cfg.mac,
        hostname = cfg.hostname,
        fqdn = cfg.fqdn,
        gateway = cfg.gateway,
        dns = cfg.dns,
        modem_available = modem_available,
        computer_id = os.getComputerID(),
        udp_enabled = network.udp_enabled or false
    }
end

-- Get network statistics
function network.getStats()
    local stats_path = "/var/run/netd.stats"
    if fs.exists(stats_path) then
        local file = fs.open(stats_path, "r")
        local data = file.readAll()
        file.close()
        local stats = textutils.unserialize(data)
        if stats then
            return stats
        end
    end

    return {
        packets_sent = 0,
        packets_received = 0,
        bytes_sent = 0,
        bytes_received = 0,
        dns_queries = 0,
        arp_requests = 0,
        http_requests = 0,
        websocket_connections = 0,
        udp_packets = 0,
        uptime = 0
    }
end

-- ==================== UDP Support ====================

-- Create UDP socket
function network.udpSocket(port, options)
    if not cfg then loadConfig() end

    -- Load UDP module if not already loaded
    if not network.udp and fs.exists("/protocols/udp.lua") then
        network.udp = dofile("/protocols/udp.lua")
    end

    if not network.udp then
        error("UDP protocol not available")
    end

    -- Create socket using UDP protocol
    local socket = network.udp.socket(port, options)

    -- Track socket for cleanup
    udp_sockets[socket.port] = socket

    return socket
end

-- Send UDP datagram (convenience function)
function network.udpSend(destIP, destPort, data, sourcePort)
    if not cfg then loadConfig() end

    -- Create temporary socket if sourcePort not specified
    local socket = nil
    local tempSocket = false

    if sourcePort and udp_sockets[sourcePort] then
        socket = udp_sockets[sourcePort]
    else
        socket = network.udpSocket(sourcePort)
        tempSocket = true
    end

    -- Send the data
    local success, err = socket:send(data, destIP, destPort)

    -- Close temporary socket
    if tempSocket then
        socket:close()
        udp_sockets[socket.port] = nil
    end

    return success, err
end

-- Listen for UDP on specific port
function network.udpListen(port, callback)
    if not cfg then loadConfig() end

    local socket = network.udpSocket(port)
    socket:bind(port)

    if callback then
        socket:setReceiveCallback(callback)
    end

    return socket
end

-- Get UDP statistics
function network.getUDPStats()
    if network.udp then
        return network.udp.getStatistics()
    end

    return {
        packets_sent = 0,
        packets_received = 0,
        bytes_sent = 0,
        bytes_received = 0,
        active_sockets = 0
    }
end

-- ==================== DNS functions ====================

-- Resolve hostname
function network.resolve(hostname)
    if not cfg then loadConfig() end
    if not modem_available then return nil, "No modem available" end

    ensureModemOpen()

    -- Check if it's an IP address
    if hostname:match("^%d+%.%d+%.%d+%.%d+$") then
        return hostname
    end

    -- Check for localhost
    if hostname == "localhost" then
        return "127.0.0.1"
    end

    -- Check for our own hostname
    if hostname == cfg.hostname or hostname == cfg.fqdn then
        return cfg.ipv4
    end

    -- Query DNS via rednet
    rednet.broadcast({
        type = "query",
        hostname = hostname
    }, cfg.dns_proto)

    -- Wait for response
    local timer = os.startTimer(3)
    while true do
        local event, param1, param2, param3 = os.pullEvent()
        if event == "rednet_message" and param3 == cfg.dns_proto then
            local message = param2
            if type(message) == "table" and message.type == "response" and message.hostname == hostname then
                os.cancelTimer(timer)
                return message.ip
            end
        elseif event == "timer" and param1 == timer then
            return nil, "DNS resolution timeout"
        end
    end
end

-- ==================== HTTP functions ====================

-- HTTP request
function network.http(url, options)
    if not cfg then loadConfig() end
    options = options or {}

    -- Parse URL
    local protocol, host, port, path
    protocol, host, port, path = url:match("^(%w+)://([^:/]+):?(%d*)(/?.*)$")
    if not protocol then
        host, port, path = url:match("^([^:/]+):?(%d*)(/?.*)$")
        protocol = "http"
    end

    port = tonumber(port) or 80
    path = path ~= "" and path or "/"

    -- Check if local or remote
    local isLocal = host == "localhost" or
            host == cfg.hostname or
            host:match("^10%.") or
            host:match("^192%.168%.")

    if isLocal and modem_available then
        -- Local HTTP via rednet
        ensureModemOpen()

        -- Create request
        local request = {
            type = "http_request",
            method = options.method or "GET",
            path = path,
            headers = options.headers or {},
            body = options.body,
            port = port,
            id = os.epoch("utc")
        }

        -- Send request
        rednet.broadcast(request, cfg.http_proto)

        -- Wait for response
        local timer = os.startTimer(options.timeout or 5)
        while true do
            local event, param1, param2, param3 = os.pullEvent()
            if event == "rednet_message" and param3 == cfg.http_proto then
                local sender, message = param1, param2
                if type(message) == "table" and message.type == "response" and message.id == request.id then
                    os.cancelTimer(timer)
                    return {
                        getResponseCode = function() return message.code end,
                        readAll = function() return message.body end,
                        close = function() end
                    }
                end
            elseif event == "timer" and param1 == timer then
                return nil, "Request timeout"
            end
        end
    else
        -- External HTTP via native API
        if protocol == "http" then
            if options.method == "POST" then
                return http.post(url, options.body, options.headers)
            else
                return http.get(url, options.headers)
            end
        elseif protocol == "https" then
            if http.checkURL then
                local ok = http.checkURL(url)
                if not ok then
                    return nil, "Invalid HTTPS URL"
                end
            end
            if options.method == "POST" then
                return http.post(url, options.body, options.headers)
            else
                return http.get(url, options.headers)
            end
        end
    end
end

-- ==================== WebSocket functions ====================

-- WebSocket connection
function network.websocket(url)
    if not cfg then loadConfig() end

    -- Parse URL
    local protocol, host, port, path
    protocol = url:match("^(%w+)://")
    if protocol then
        host, port, path = url:match("^%w+://([^:/]+):?(%d*)(/?.*)$")
    else
        host, port, path = url:match("^([^:/]+):?(%d*)(/?.*)$")
        protocol = "ws"
    end

    port = tonumber(port) or 80
    path = path ~= "" and path or "/"

    -- Check if local or remote
    local isLocal = host == "localhost" or
            host == cfg.hostname or
            host:match("^10%.") or
            host:match("^192%.168%.")

    if isLocal and modem_available then
        -- Local WebSocket via rednet
        ensureModemOpen()

        local connectionId = "ws_" .. os.epoch("utc") .. "_" .. math.random(1000)

        -- Send connection request
        rednet.broadcast({
            type = "ws_connect",
            connectionId = connectionId,
            url = {host = host, port = port, path = path}
        }, cfg.ws_proto)

        -- Wait for acceptance
        local timer = os.startTimer(5)
        local accepted = false
        local peerId = nil

        while not accepted do
            local event, param1, param2, param3 = os.pullEvent()
            if event == "rednet_message" and param3 == cfg.ws_proto then
                local sender, message = param1, param2
                if type(message) == "table" and message.connectionId == connectionId then
                    if message.type == "ws_accept" or message.type == "accept" then
                        accepted = true
                        peerId = sender
                        os.cancelTimer(timer)
                    elseif message.type == "ws_reject" or message.type == "reject" then
                        os.cancelTimer(timer)
                        return nil, message.reason or "Connection rejected"
                    end
                end
            elseif event == "timer" and param1 == timer then
                return nil, "Connection timeout"
            end
        end

        -- Return WebSocket object with UDP-like interface
        return {
            send = function(data)
                rednet.send(peerId, {
                    type = "ws_data",
                    connectionId = connectionId,
                    data = data
                }, cfg.ws_proto)
            end,

            receive = function(timeout)
                local timer = nil
                if timeout then timer = os.startTimer(timeout) end

                while true do
                    local event, param1, param2, param3 = os.pullEvent()
                    if event == "rednet_message" and param3 == cfg.ws_proto then
                        local sender, message = param1, param2
                        if sender == peerId and type(message) == "table" and
                                message.connectionId == connectionId and message.type == "ws_data" then
                            if timer then os.cancelTimer(timer) end
                            return message.data
                        end
                    elseif event == "timer" and timer and param1 == timer then
                        return nil, "Receive timeout"
                    end
                end
            end,

            close = function()
                rednet.send(peerId, {
                    type = "ws_close",
                    connectionId = connectionId
                }, cfg.ws_proto)
            end
        }
    else
        -- External WebSocket via native API
        local fullUrl = protocol .. "://" .. host .. ":" .. port .. path
        if protocol:match("^wss?$") then
            return http.websocket(fullUrl)
        else
            return nil, "Invalid WebSocket protocol"
        end
    end
end

-- ==================== Server functions ====================

-- HTTP server (existing implementation)
function network.httpServer(port, handler)
    if not cfg then loadConfig() end
    if not modem_available then
        return nil, "No modem available"
    end

    port = port or 80

    -- Store handler in memory
    active_servers[port] = {
        port = port,
        handler = handler,
        type = "http"
    }

    -- Notify netd about the server by sending a registration message
    ensureModemOpen()
    rednet.broadcast({
        type = "server_register",
        port = port,
        protocol = "http"
    }, cfg.proto)

    return {
        port = port,
        stop = function()
            active_servers[port] = nil
            rednet.broadcast({
                type = "server_unregister",
                port = port
            }, cfg.proto)
        end,

        listen = function()
            ensureModemOpen()
            while active_servers[port] do
                local event, sender, message, protocol = os.pullEvent("rednet_message")
                if protocol == cfg.http_proto and type(message) == "table" and
                        (message.type == "http_request" or message.type == "request") then
                    if message.port == port then
                        -- Process request
                        local request = {
                            method = message.method or "GET",
                            path = message.path or "/",
                            headers = message.headers or {},
                            body = message.body,
                            source = sender
                        }

                        local response = handler(request)
                        if response then
                            rednet.send(sender, {
                                type = "response",
                                id = message.id,
                                code = response.code or 200,
                                headers = response.headers or {},
                                body = response.body or ""
                            }, cfg.http_proto)
                        end
                    end
                end
            end
        end
    }
end

-- WebSocket server (existing implementation)
function network.wsServer(port, handler)
    if not cfg then loadConfig() end
    if not modem_available then
        return nil, "No modem available"
    end

    port = port or 8080

    -- Store handler
    active_servers[port] = {
        port = port,
        handler = handler,
        type = "websocket"
    }

    -- Register with netd
    ensureModemOpen()
    rednet.broadcast({
        type = "server_register",
        port = port,
        protocol = "websocket"
    }, cfg.proto)

    return {
        port = port,
        stop = function()
            active_servers[port] = nil
            rednet.broadcast({
                type = "server_unregister",
                port = port
            }, cfg.proto)
        end,

        listen = function()
            ensureModemOpen()
            local connections = {}

            while active_servers[port] do
                local event, param1, param2, param3 = os.pullEvent()

                if event == "rednet_message" and param3 == cfg.ws_proto then
                    local sender, message = param1, param2

                    if type(message) == "table" then
                        if message.type == "ws_connect" and message.url and message.url.port == port then
                            -- Accept connection
                            local connId = message.connectionId
                            connections[connId] = {
                                peer = sender,
                                established = os.epoch("utc")
                            }

                            rednet.send(sender, {
                                type = "ws_accept",
                                connectionId = connId
                            }, cfg.ws_proto)

                            if handler then
                                handler("connect", connId, nil)
                            end

                        elseif message.type == "ws_data" and connections[message.connectionId] then
                            -- Handle data
                            if handler then
                                handler("data", message.connectionId, message.data)
                            end

                        elseif message.type == "ws_close" and connections[message.connectionId] then
                            -- Handle close
                            if handler then
                                handler("close", message.connectionId, nil)
                            end
                            connections[message.connectionId] = nil
                        end
                    end
                end
            end
        end
    }
end

-- Cleanup function
function network.cleanup()
    -- Close all UDP sockets
    for port, socket in pairs(udp_sockets) do
        socket:close()
    end
    udp_sockets = {}

    -- Stop all servers
    for port, server in pairs(active_servers) do
        rednet.broadcast({
            type = "server_unregister",
            port = port
        }, cfg.proto)
    end
    active_servers = {}
end

return network