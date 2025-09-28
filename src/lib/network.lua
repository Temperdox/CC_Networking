-- /lib/network.lua
-- Network library for interacting with netd
-- Provides high-level network functions for applications
-- FIXED: HTTP server implementation

local network = {}

-- Cache configuration
local cfg = nil
local cfg_loaded = false
local modem_available = false
local active_servers = {}  -- Store server handlers in memory

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
                    ws_proto = "ccnet_ws"
                }
                modem_available = info.modem_available or false
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
                computer_id = os.getComputerID()
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
        computer_id = os.getComputerID()
    }
end

-- Get network statistics
function network.getStats()
    local stats_path = "/var/run/netd.stats"
    if fs.exists(stats_path) then
        local file = fs.open(stats_path, "r")
        local data = file.readAll()
        file.close()
        return textutils.unserialize(data)
    end
    return nil
end

-- Discover network devices
function network.discover(timeout)
    if not cfg then loadConfig() end
    if not modem_available then return {} end

    ensureModemOpen()
    timeout = timeout or 3

    -- Send discovery broadcast
    rednet.broadcast({type = "query"}, cfg.discovery_proto)

    local devices = {}
    local endTime = os.clock() + timeout

    while os.clock() < endTime do
        local remaining = endTime - os.clock()
        if remaining <= 0 then break end

        local timer = os.startTimer(remaining)
        local event, sender, message, protocol = os.pullEvent()

        if event == "rednet_message" and protocol == cfg.discovery_proto then
            if type(message) == "table" and message.type == "response" then
                table.insert(devices, {
                    id = sender,
                    hostname = message.hostname,
                    ip = message.ip,
                    mac = message.mac,
                    services = message.services or {}
                })
            end
        elseif event == "timer" and sender == timer then
            break
        else
            os.cancelTimer(timer)
        end
    end

    return devices
end

-- DNS resolution
function network.resolve(hostname)
    if not cfg then loadConfig() end

    -- Check special cases
    if hostname == "localhost" then
        return "127.0.0.1"
    elseif hostname == cfg.hostname or hostname == cfg.fqdn then
        return cfg.ipv4
    end

    if not modem_available then return nil end

    ensureModemOpen()

    -- Send DNS query
    rednet.broadcast({type = "query", hostname = hostname}, cfg.dns_proto)

    -- Wait for response
    local timer = os.startTimer(2)
    while true do
        local event, param1, param2, param3 = os.pullEvent()
        if event == "rednet_message" and param3 == cfg.dns_proto then
            local sender, message = param1, param2
            if type(message) == "table" and message.type == "response" and message.hostname == hostname then
                os.cancelTimer(timer)
                return message.ip
            end
        elseif event == "timer" and param1 == timer then
            return nil
        end
    end
end

-- Ping
function network.ping(target, count)
    if not cfg then loadConfig() end
    if not modem_available then return nil end

    ensureModemOpen()

    -- Resolve target if needed
    local targetIp = target
    if not target:match("^%d+%.%d+%.%d+%.%d+$") then
        targetIp = network.resolve(target)
        if not targetIp then
            return {sent = 0, received = 0, lost = 0}
        end
    end

    count = count or 4
    local results = {
        sent = 0,
        received = 0,
        lost = 0,
        times = {}
    }

    for i = 1, count do
        results.sent = results.sent + 1
        local startTime = os.epoch("utc")

        rednet.broadcast({
            type = "ping",
            seq = i,
            source = cfg.ipv4,
            dest = targetIp,
            timestamp = startTime
        }, "ping_" .. cfg.ipv4)

        local timer = os.startTimer(1)
        local gotReply = false

        while not gotReply do
            local event, param1, param2, param3 = os.pullEvent()
            if event == "rednet_message" and param3 == "pong_" .. cfg.ipv4 then
                local sender, message = param1, param2
                if type(message) == "table" and message.type == "pong" and message.seq == i then
                    local endTime = os.epoch("utc")
                    local rtt = endTime - startTime
                    table.insert(results.times, rtt)
                    results.received = results.received + 1
                    gotReply = true
                    os.cancelTimer(timer)
                end
            elseif event == "timer" and param1 == timer then
                results.lost = results.lost + 1
                break
            end
        end
    end

    -- Calculate statistics
    if #results.times > 0 then
        local sum = 0
        results.min_time = results.times[1]
        results.max_time = results.times[1]

        for _, time in ipairs(results.times) do
            sum = sum + time
            if time < results.min_time then results.min_time = time end
            if time > results.max_time then results.max_time = time end
        end

        results.avg_time = sum / #results.times
    end

    return results
end

-- HTTP client
function network.http(url, options)
    if not cfg then loadConfig() end
    options = options or {}

    -- Parse URL
    local protocol, host, port, path = url:match("^(%w+)://([^:/]+):?(%d*)(/?.*)$")
    if not protocol then
        host, port, path = url:match("^([^:/]+):?(%d*)(/?.*)$")
        protocol = "http"
    end

    port = tonumber(port) or 80
    path = path ~= "" and path or "/"

    -- Check if local or remote
    local isLocal = host == "localhost" or
            host == cfg.hostname or
            host == cfg.fqdn or
            host:match("^10%.") or
            host:match("^192%.168%.") or
            host:match("^cc%-")

    if isLocal and modem_available then
        ensureModemOpen()

        -- Resolve hostname to computer ID
        local targetId = nil
        if host == "localhost" or host == cfg.hostname then
            targetId = os.getComputerID()
        else
            -- Broadcast discovery to find target
            rednet.broadcast({type = "id_query", ip = host}, cfg.discovery_proto)
            local timer = os.startTimer(2)

            while true do
                local event, param1, param2, param3 = os.pullEvent()
                if event == "rednet_message" and param3 == cfg.discovery_proto then
                    local sender, message = param1, param2
                    if type(message) == "table" and message.type == "id_response" and message.ip == host then
                        targetId = sender
                        os.cancelTimer(timer)
                        break
                    end
                elseif event == "timer" and param1 == timer then
                    break
                end
            end
        end

        if not targetId then
            -- Try to resolve via hostname
            rednet.broadcast({type = "query"}, cfg.discovery_proto)
            local timer = os.startTimer(2)

            while true do
                local event, param1, param2, param3 = os.pullEvent()
                if event == "rednet_message" and param3 == cfg.discovery_proto then
                    local sender, message = param1, param2
                    if type(message) == "table" and message.hostname == host then
                        targetId = sender
                        os.cancelTimer(timer)
                        break
                    end
                elseif event == "timer" and param1 == timer then
                    return nil, "Host not found"
                end
            end
        end

        -- Create HTTP request packet
        local requestId = math.random(1000000)
        local packet = {
            type = "request",
            id = requestId,
            method = options.method or "GET",
            path = path,
            port = port,
            headers = options.headers or {},
            body = options.body,
            timestamp = os.epoch("utc")
        }

        -- Send to target
        if targetId == os.getComputerID() then
            -- Local request - send via broadcast for netd to handle
            rednet.broadcast(packet, cfg.http_proto)
        else
            rednet.send(targetId, packet, cfg.http_proto)
        end

        -- Wait for response
        local timeout = os.startTimer(options.timeout or 5)

        while true do
            local event, param1, param2, param3 = os.pullEvent()
            if event == "rednet_message" and param3 == cfg.http_proto then
                local sender, response = param1, param2
                if type(response) == "table" and response.type == "response" and response.id == requestId then
                    os.cancelTimer(timeout)

                    -- Create response object
                    return {
                        readAll = function() return response.body end,
                        getResponseCode = function() return response.code end,
                        getResponseHeaders = function() return response.headers end,
                        close = function() end
                    }
                end
            elseif event == "timer" and param1 == timeout then
                return nil, "Request timeout"
            end
        end
    else
        -- Remote request using native HTTP
        if options.method == "GET" then
            return http.get(url, options.headers)
        elseif options.method == "POST" then
            return http.post(url, options.body, options.headers)
        else
            return http.request({
                url = url,
                method = options.method,
                headers = options.headers,
                body = options.body
            })
        end
    end
end

-- Create HTTP server (local network only)
function network.createServer(port, handler)
    if not cfg then loadConfig() end
    if not modem_available then
        return nil, "No modem available for local server"
    end

    ensureModemOpen()

    -- Store the handler in memory
    active_servers[port] = {
        handler = handler,
        created = os.epoch("utc"),
        port = port
    }

    -- Register server with netd by sending a message
    rednet.broadcast({
        type = "register_server",
        port = port,
        hostname = cfg.hostname,
        ip = cfg.ipv4
    }, cfg.http_proto)

    -- Start server loop in a coroutine
    local serverRunning = true

    local function serverLoop()
        while serverRunning do
            local sender, message, protocol = rednet.receive()

            if protocol == cfg.http_proto and type(message) == "table" then
                if (message.type == "request" or message.type == "http_request") and
                        (message.port == port or (message.port == nil and port == 80)) then

                    -- Call the handler
                    local success, result = pcall(handler, {
                        method = message.method or "GET",
                        path = message.path or "/",
                        headers = message.headers or {},
                        body = message.body or "",
                        query = message.query or {},
                        source = sender
                    })

                    local response
                    if success and type(result) == "table" then
                        response = result
                    elseif success then
                        -- Handler returned non-table, treat as body
                        response = {
                            code = 200,
                            headers = {["Content-Type"] = "text/plain"},
                            body = tostring(result)
                        }
                    else
                        -- Handler error
                        response = {
                            code = 500,
                            headers = {["Content-Type"] = "text/plain"},
                            body = "Internal Server Error"
                        }
                    end

                    -- Ensure response has required fields
                    response.type = "response"
                    response.id = message.id
                    response.code = response.code or 200
                    response.headers = response.headers or {}
                    response.body = response.body or ""
                    response.timestamp = os.epoch("utc")

                    -- Send response back
                    rednet.send(sender, response, cfg.http_proto)
                end
            elseif protocol == "server_control" and type(message) == "table" then
                if message.action == "stop" and message.port == port then
                    serverRunning = false
                    break
                end
            end
        end

        -- Cleanup
        active_servers[port] = nil
    end

    -- Return server control object
    return {
        port = port,
        stop = function()
            serverRunning = false
            active_servers[port] = nil
            rednet.broadcast({action = "stop", port = port}, "server_control")
        end,
        isRunning = function()
            return serverRunning
        end,
        start = function()
            return parallel.waitForAny(serverLoop)
        end
    }
end

-- Stop a server
function network.stopServer(port)
    if active_servers[port] then
        active_servers[port] = nil
        rednet.broadcast({action = "stop", port = port}, "server_control")
        return true
    end
    return false
end

-- List active servers
function network.getActiveServers()
    local servers = {}
    for port, server in pairs(active_servers) do
        table.insert(servers, {
            port = port,
            created = server.created
        })
    end
    return servers
end

-- WebSocket client (supports both local and remote)
function network.websocket(url)
    if not cfg then loadConfig() end

    -- Parse URL
    local protocol, host, port, path = url:match("^(%w+)://([^:/]+):?(%d*)(/?.*)$")
    if not protocol then
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

        -- Return WebSocket object
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
                        return nil
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
        -- Remote WebSocket using native API
        local ws_url = url:gsub("^http", "ws")
        return http.websocket(ws_url)
    end
end

return network