-- /lib/network.lua
-- Network library for interacting with netd
-- Provides high-level network functions for applications

local network = {}

-- Cache configuration
local cfg = nil
local cfg_loaded = false
local modem_available = false

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

-- Open modem if not already open
local function ensureModemOpen()
    if not modem_available then
        return false
    end

    if not rednet.isOpen() then
        local modem = peripheral.find("modem")
        if modem then
            local side = peripheral.getName(modem)
            rednet.open(side)
            return true
        end
        return false
    end
    return true
end

-- Ensure configuration is loaded
loadConfig()

-- Check if netd is running
function network.isDaemonRunning()
    return fs.exists("/var/run/netd.pid")
end

-- Get network information
function network.getInfo()
    if not cfg then loadConfig() end

    return {
        id = cfg.id,
        hostname = cfg.hostname,
        fqdn = cfg.fqdn,
        mac = cfg.mac,
        ip = cfg.ipv4,
        subnet_mask = cfg.subnet_mask,
        gateway = cfg.gateway,
        dns = cfg.dns,
        modem_available = modem_available
    }
end

-- Get network statistics
function network.getStats()
    local stats_file = "/var/run/netd.stats"
    if fs.exists(stats_file) then
        local file = fs.open(stats_file, "r")
        if file then
            local data = file.readAll()
            file.close()
            return textutils.unserialize(data)
        end
    end
    return nil
end

-- Check if an address is local or remote
function network.isLocal(address)
    -- Check for local indicators
    if address:find("%.local") or
            address:find("^localhost") or
            address:find("^127%.") or
            address:find("^10%.0%.") or
            address:find("^cc%-") then
        return true
    end
    return false
end

-- DNS Resolution
function network.resolve(hostname)
    if not cfg then loadConfig() end

    -- Check if it's already an IP
    if hostname:match("^%d+%.%d+%.%d+%.%d+$") then
        return hostname
    end

    -- Special cases
    if hostname == "localhost" or hostname == "127.0.0.1" then
        return "127.0.0.1"
    end

    -- Check if it's our hostname
    if hostname == cfg.hostname or hostname == cfg.fqdn then
        return cfg.ipv4
    end

    -- For local hostnames, use rednet
    if network.isLocal(hostname) and modem_available then
        ensureModemOpen()

        -- Remove .local suffix if present
        local clean_hostname = hostname:gsub("%.local$", "")

        -- Check cache (if netd is running)
        local cache_file = "/var/cache/netd.state"
        if fs.exists(cache_file) then
            local file = fs.open(cache_file, "r")
            if file then
                local data = file.readAll()
                file.close()
                local state = textutils.unserialize(data)
                if state and state.dns_cache then
                    local cached = state.dns_cache[hostname] or state.dns_cache[clean_hostname]
                    if cached and cached.expires > os.epoch("utc") then
                        return cached.ip
                    end
                end
            end
        end

        -- Query network for hostname
        local query = {
            type = "query",
            hostname = hostname,
            id = os.epoch("utc")
        }

        rednet.broadcast(query, cfg.dns_proto)

        -- Wait for response
        local timeout = os.startTimer(2)
        while true do
            local event, param1, param2, param3 = os.pullEvent()

            if event == "rednet_message" and param3 == cfg.dns_proto then
                local sender, message = param1, param2
                if type(message) == "table" and
                        message.type == "response" and
                        (message.hostname == hostname or message.hostname == clean_hostname) then
                    os.cancelTimer(timeout)
                    return message.ip
                end
            elseif event == "timer" and param1 == timeout then
                break
            end
        end
    end

    return nil
end

-- ARP Resolution (local network only)
function network.arp(ip)
    if not cfg then loadConfig() end
    if not modem_available then return nil end

    ensureModemOpen()

    -- Check if it's our IP
    if ip == cfg.ipv4 then
        return cfg.mac
    end

    -- Check cache
    local cache_file = "/var/cache/netd.state"
    if fs.exists(cache_file) then
        local file = fs.open(cache_file, "r")
        if file then
            local data = file.readAll()
            file.close()
            local state = textutils.unserialize(data)
            if state and state.arp_cache then
                local cached = state.arp_cache[ip]
                if cached and cached.expires > os.epoch("utc") then
                    return cached.mac
                end
            end
        end
    end

    -- ARP request
    local request = {
        type = "request",
        ip = ip,
        sender_ip = cfg.ipv4,
        sender_mac = cfg.mac
    }

    rednet.broadcast(request, cfg.arp_proto)

    -- Wait for response
    local timeout = os.startTimer(1)
    while true do
        local event, param1, param2, param3 = os.pullEvent()

        if event == "rednet_message" and param3 == cfg.arp_proto then
            local sender, message = param1, param2
            if type(message) == "table" and
                    message.type == "reply" and
                    message.ip == ip then
                os.cancelTimer(timeout)
                return message.mac
            end
        elseif event == "timer" and param1 == timeout then
            break
        end
    end

    return nil
end

-- Ping utility (works for both local and remote)
function network.ping(host, count)
    if not cfg then loadConfig() end

    count = count or 4
    local results = {
        host = host,
        ip = nil,
        sent = 0,
        received = 0,
        lost = 0,
        times = {}
    }

    -- Check if local or remote
    if network.isLocal(host) and modem_available then
        -- Local network ping using rednet
        ensureModemOpen()

        local ip = network.resolve(host) or host
        results.ip = ip

        if not ip then
            return nil, "Cannot resolve host"
        end

        for i = 1, count do
            local packet = {
                type = "ping",
                seq = i,
                timestamp = os.epoch("utc"),
                source = cfg.ipv4
            }

            local start = os.epoch("utc")
            rednet.broadcast(packet, "ping_" .. ip)

            local timeout = os.startTimer(1)
            local received = false

            while true do
                local event, param1, param2, param3 = os.pullEvent()

                if event == "rednet_message" and param3 == "pong_" .. cfg.ipv4 then
                    local sender, message = param1, param2
                    if type(message) == "table" and
                            message.type == "pong" and
                            message.seq == i then
                        local time = os.epoch("utc") - start
                        table.insert(results.times, time)
                        results.received = results.received + 1
                        received = true
                        os.cancelTimer(timeout)
                        break
                    end
                elseif event == "timer" and param1 == timeout then
                    results.lost = results.lost + 1
                    break
                end
            end

            results.sent = results.sent + 1

            -- Small delay between pings
            if i < count then
                sleep(0.5)
            end
        end
    else
        -- Remote ping - would need HTTP endpoint or similar
        return nil, "Remote ping not supported"
    end

    -- Calculate statistics
    if #results.times > 0 then
        local sum = 0
        results.min = math.huge
        results.max = -math.huge

        for _, time in ipairs(results.times) do
            sum = sum + time
            results.min = math.min(results.min, time)
            results.max = math.max(results.max, time)
        end

        results.avg = sum / #results.times
        results.loss = (results.lost / results.sent) * 100
    else
        results.loss = 100
    end

    return results
end

-- Discover network devices (local network only)
function network.discover(timeout)
    if not cfg then loadConfig() end
    if not modem_available then
        return {}, "No modem available for local discovery"
    end

    ensureModemOpen()

    timeout = timeout or 5
    local devices = {}

    -- Send discovery query
    rednet.broadcast({type = "query"}, cfg.discovery_proto)

    -- Collect responses
    local timer = os.startTimer(timeout)
    while true do
        local event, param1, param2, param3 = os.pullEvent()

        if event == "rednet_message" and param3 == cfg.discovery_proto then
            local sender, message = param1, param2
            if type(message) == "table" and message.type == "response" then
                devices[message.ip or tostring(sender)] = {
                    id = message.id or sender,
                    hostname = message.hostname,
                    mac = message.mac,
                    ip = message.ip,
                    services = message.services or {},
                    fqdn = message.fqdn
                }
            end
        elseif event == "timer" and param1 == timer then
            break
        end
    end

    return devices
end

-- Get computer ID for IP (local network only)
function network.getComputerForIP(ip)
    if not cfg then loadConfig() end
    if not modem_available then return nil end

    ensureModemOpen()

    -- Check ARP cache first
    local cache_file = "/var/cache/netd.state"
    if fs.exists(cache_file) then
        local file = fs.open(cache_file, "r")
        if file then
            local data = file.readAll()
            file.close()
            local state = textutils.unserialize(data)
            if state and state.arp_cache then
                local cached = state.arp_cache[ip]
                if cached and cached.computer_id then
                    return cached.computer_id
                end
            end
        end
    end

    -- Query network
    local query = {
        type = "id_query",
        ip = ip
    }

    rednet.broadcast(query, cfg.discovery_proto)

    -- Wait for response
    local timeout = os.startTimer(2)
    while true do
        local event, param1, param2, param3 = os.pullEvent()

        if event == "rednet_message" then
            local sender, message = param1, param2
            if type(message) == "table" and
                    (message.ip == ip or
                            (message.type == "id_response" and message.ip == ip)) then
                os.cancelTimer(timeout)
                return sender
            end
        elseif event == "timer" and param1 == timeout then
            break
        end
    end

    return nil
end

-- HTTP Client wrapper (supports both local and remote)
function network.http(url, options)
    if not cfg then loadConfig() end

    options = options or {}

    -- Parse URL
    local protocol, host, port, path = url:match("^(%w+)://([^:/]+):?(%d*)(/?.*)$")
    if not protocol then
        host, port, path = url:match("^([^:/]+):?(%d*)(/?.*)$")
        protocol = "http"
    end

    port = tonumber(port) or (protocol == "https" and 443 or 80)
    path = path ~= "" and path or "/"

    -- Check if local or remote
    if network.isLocal(host) and modem_available then
        -- Local network request via rednet
        ensureModemOpen()

        -- Resolve hostname
        local ip = network.resolve(host) or host

        -- Get destination computer ID
        local destId = network.getComputerForIP(ip)
        if not destId then
            return nil, "Host not reachable on local network"
        end

        local packet = {
            type = "http_request",
            id = os.epoch("utc"),
            method = options.method or "GET",
            protocol = protocol,
            host = host,
            port = port,
            path = path,
            headers = options.headers or {},
            body = options.body,
            source = {
                ip = cfg.ipv4,
                mac = cfg.mac,
                port = math.random(1024, 65535)
            },
            timestamp = os.epoch("utc")
        }

        rednet.send(destId, packet, cfg.http_proto)

        -- Wait for response
        local timeout = os.startTimer(options.timeout or 5)
        while true do
            local event, param1, param2, param3 = os.pullEvent()

            if event == "rednet_message" and param3 == cfg.http_proto then
                local sender, response = param1, param2
                if type(response) == "table" and
                        (response.type == "response" or response.type == "http_response") and
                        response.id == packet.id then
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

    -- Register server with netd by writing to a file
    local server_config = {
        port = port,
        handler = handler,
        created = os.epoch("utc")
    }

    -- Store server configuration
    local server_dir = "/var/run/servers"
    if not fs.exists(server_dir) then
        fs.makeDir(server_dir)
    end

    local server_file = server_dir .. "/http_" .. port .. ".conf"
    local file = fs.open(server_file, "w")
    if file then
        file.write(textutils.serialize(server_config))
        file.close()
    end

    -- Start server loop
    parallel.waitForAny(function()
        while true do
            local sender, message, protocol = rednet.receive()

            if protocol == cfg.http_proto or protocol == "network_adapter_http" then
                if type(message) == "table" and
                        (message.type == "request" or message.type == "http_request") and
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

                    rednet.send(sender, responsePacket, protocol)
                end
            end
        end
    end)

    return true
end

-- WebSocket client (supports both local and remote)
function network.websocket(url)
    if not cfg then loadConfig() end

    -- Parse URL
    local protocol, host, port, path = url:match("^(%w+)://([^:/]+):?(%d*)(/?.*)$")
    port = tonumber(port) or 8080
    path = path ~= "" and path or "/"

    -- Check if local or remote
    if network.isLocal(host) and modem_available then
        -- Local WebSocket via rednet
        ensureModemOpen()

        -- Resolve hostname
        local ip = network.resolve(host) or host

        -- Get destination computer ID
        local destId = network.getComputerForIP(ip)
        if not destId then
            return nil, "Host not reachable on local network"
        end

        local ws = {
            url = url,
            destId = destId,
            connected = false,
            connectionId = os.epoch("utc") .. "_" .. math.random(1000, 9999),
            receiveQueue = {}
        }

        function ws:connect()
            local packet = {
                type = "ws_connect",
                connectionId = self.connectionId,
                url = {
                    protocol = protocol,
                    host = host,
                    port = port,
                    path = path
                },
                source = {
                    ip = cfg.ipv4,
                    mac = cfg.mac
                },
                timestamp = os.epoch("utc")
            }

            rednet.send(self.destId, packet, cfg.ws_proto)

            -- Wait for response
            local timeout = os.startTimer(5)
            while true do
                local event, param1, param2, param3 = os.pullEvent()

                if event == "rednet_message" and
                        (param3 == cfg.ws_proto or param3 == "network_adapter_ws") then
                    local sender, response = param1, param2
                    if type(response) == "table" and
                            response.connectionId == self.connectionId then
                        os.cancelTimer(timeout)
                        if response.type == "accept" or response.type == "ws_accept" then
                            self.connected = true
                            -- Start receive loop
                            self:startReceiveLoop()
                            return true
                        else
                            return false, response.reason or "Connection rejected"
                        end
                    end
                elseif event == "timer" and param1 == timeout then
                    return false, "Connection timeout"
                end
            end
        end

        function ws:startReceiveLoop()
            parallel.waitForAny(function()
                while self.connected do
                    local sender, message, protocol = rednet.receive(0.1)
                    if message and
                            (protocol == cfg.ws_proto or protocol == "network_adapter_ws") and
                            type(message) == "table" and
                            message.connectionId == self.connectionId then
                        if message.type == "data" or message.type == "ws_data" then
                            table.insert(self.receiveQueue, message.data)
                        elseif message.type == "close" or message.type == "ws_close" then
                            self.connected = false
                            break
                        end
                    end
                end
            end)
        end

        function ws:send(data)
            if not self.connected then
                return false, "Not connected"
            end

            local packet = {
                type = "ws_data",
                connectionId = self.connectionId,
                data = data,
                timestamp = os.epoch("utc")
            }

            rednet.send(self.destId, packet, cfg.ws_proto)
            return true
        end

        function ws:receive(timeout)
            if #self.receiveQueue > 0 then
                return table.remove(self.receiveQueue, 1)
            end

            local timer = timeout and os.startTimer(timeout)

            while true do
                if #self.receiveQueue > 0 then
                    if timer then os.cancelTimer(timer) end
                    return table.remove(self.receiveQueue, 1)
                end

                local event, param1 = os.pullEvent()
                if event == "timer" and timer and param1 == timer then
                    return nil
                end

                -- Small yield to check queue
                sleep(0.05)
            end
        end

        function ws:close()
            if self.connected then
                local packet = {
                    type = "ws_close",
                    connectionId = self.connectionId,
                    timestamp = os.epoch("utc")
                }

                rednet.send(self.destId, packet, cfg.ws_proto)
                self.connected = false
            end
        end

        -- Auto-connect
        ws:connect()

        return ws
    else
        -- Remote WebSocket using native API
        return http.websocket(url)
    end
end

-- Get local network info
function network.getLocalInfo()
    return network.getInfo()
end

-- Utility to format bytes
function network.formatBytes(bytes)
    if bytes < 1024 then
        return string.format("%d B", bytes)
    elseif bytes < 1024 * 1024 then
        return string.format("%.2f KB", bytes / 1024)
    elseif bytes < 1024 * 1024 * 1024 then
        return string.format("%.2f MB", bytes / (1024 * 1024))
    else
        return string.format("%.2f GB", bytes / (1024 * 1024 * 1024))
    end
end

return network