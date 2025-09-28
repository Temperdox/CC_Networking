#!/usr/bin/env lua
-- /bin/netd.lua
-- Network daemon for ComputerCraft
-- Provides network services and protocol handling

local version = "1.0.0"
local daemon_name = "netd"

-- Check if already running
if fs.exists("/var/run/netd.pid") then
    local pidFile = fs.open("/var/run/netd.pid", "r")
    if pidFile then
        local pid = pidFile.readAll()
        pidFile.close()
        print("[netd] Already running (PID: " .. pid .. ")")
        return
    end
end

-- Load configuration
local function loadConfig()
    local config_path = "/config/network.cfg"
    if not fs.exists(config_path) then
        error("[netd] Configuration file not found: " .. config_path)
    end

    local file = fs.open(config_path, "r")
    local content = file.readAll()
    file.close()

    local func, err = loadstring(content)
    if not func then
        error("[netd] Failed to parse config: " .. err)
    end

    return func()
end

local cfg = loadConfig()

-- Logger setup
local logger = {
    levels = {
        trace = 1,
        debug = 2,
        info = 3,
        warn = 4,
        error = 5
    },
    current_level = 3,
    log_file = nil,
    entries = {},
    max_entries = 1000
}

function logger:init()
    if cfg.logging and cfg.logging.enabled then
        self.current_level = self.levels[cfg.logging.level] or 3
        self.max_entries = cfg.logging.max_size or 1000

        -- Create log directory if needed
        local log_dir = fs.getDir(cfg.logging.file)
        if log_dir ~= "" and not fs.exists(log_dir) then
            fs.makeDir(log_dir)
        end

        -- Open log file
        self.log_file = fs.open(cfg.logging.file, "a")
    end
end

function logger:log(level, msg, ...)
    if self.levels[level] >= self.current_level then
        local timestamp = os.date and os.date("%Y-%m-%d %H:%M:%S") or os.time()
        local formatted = string.format(msg, ...)
        local log_line = string.format("[%s] [%s] %s", timestamp, level:upper(), formatted)

        -- Print to console
        print(log_line)

        -- Write to file
        if self.log_file then
            self.log_file.writeLine(log_line)
            self.log_file.flush()
        end

        -- Store in memory (limited)
        table.insert(self.entries, log_line)
        if #self.entries > self.max_entries then
            table.remove(self.entries, 1)
        end
    end
end

function logger:trace(msg, ...) self:log("trace", msg, ...) end
function logger:debug(msg, ...) self:log("debug", msg, ...) end
function logger:info(msg, ...) self:log("info", msg, ...) end
function logger:warn(msg, ...) self:log("warn", msg, ...) end
function logger:error(msg, ...) self:log("error", msg, ...) end

-- Initialize logger
logger:init()

-- Network state (persistent)
local state_file = "/var/cache/netd.state"
local network_state = {}

-- Load saved state
local function loadState()
    if fs.exists(state_file) then
        local file = fs.open(state_file, "r")
        if file then
            local data = file.readAll()
            file.close()
            local loaded = textutils.unserialize(data)
            if loaded then
                network_state = loaded
                logger:debug("Loaded network state from cache")
            end
        end
    end

    -- Initialize missing fields
    network_state.running = true
    network_state.start_time = network_state.start_time or os.epoch("utc")
    network_state.dns_cache = network_state.dns_cache or {}
    network_state.arp_cache = network_state.arp_cache or {}
    network_state.route_cache = network_state.route_cache or {}
    network_state.connections = network_state.connections or {}
    network_state.servers = network_state.servers or {}
    network_state.stats = network_state.stats or {
        packets_sent = 0,
        packets_received = 0,
        bytes_sent = 0,
        bytes_received = 0,
        errors = 0,
        uptime = 0
    }
end

-- Save state
local function saveState()
    local file = fs.open(state_file, "w")
    if file then
        -- Don't save transient data
        local to_save = {
            dns_cache = network_state.dns_cache,
            arp_cache = network_state.arp_cache,
            stats = network_state.stats
        }
        file.write(textutils.serialize(to_save))
        file.close()
    end
end

-- Open modem
local function openModem()
    -- Check if already open
    if rednet.isOpen() then
        logger:debug("Rednet already open")
        return true
    end

    if cfg.modem_side == "auto" then
        -- Find any modem
        local modem = peripheral.find("modem")
        if modem then
            local side = peripheral.getName(modem)
            rednet.open(side)
            logger:info("Modem found and opened on side: %s", side)
            return true
        end
    else
        -- Try specific side
        if peripheral.isPresent(cfg.modem_side) and peripheral.getType(cfg.modem_side) == "modem" then
            rednet.open(cfg.modem_side)
            logger:info("Modem opened on side: %s", cfg.modem_side)
            return true
        end
    end

    logger:warn("No modem found - local network features disabled")
    return false
end

-- Initialize network
local function initNetwork()
    logger:info("Starting %s v%s", daemon_name, version)
    logger:info("Computer ID: %d, Hostname: %s", cfg.id, cfg.hostname)
    logger:info("MAC: %s, IP: %s", cfg.mac, cfg.ipv4)

    -- Load saved state
    loadState()

    -- Open modem for local network
    local modem_opened = openModem()

    if modem_opened then
        -- Register hostname with rednet for local network
        rednet.host(cfg.proto, cfg.hostname)
        logger:debug("Registered hostname: %s", cfg.hostname)
    end

    -- Create runtime directories
    local dirs = {"/var", "/var/run", "/var/cache", "/var/log"}
    for _, dir in ipairs(dirs) do
        if not fs.exists(dir) then
            fs.makeDir(dir)
        end
    end

    -- Write PID file
    local pid_file = fs.open("/var/run/netd.pid", "w")
    if pid_file then
        pid_file.write(tostring(cfg.id))
        pid_file.close()
    end

    -- Write network info file for other programs
    local info_file = fs.open("/var/run/network.info", "w")
    if info_file then
        info_file.write(textutils.serialize({
            ip = cfg.ipv4,
            mac = cfg.mac,
            hostname = cfg.hostname,
            fqdn = cfg.fqdn,
            gateway = cfg.gateway,
            dns = cfg.dns,
            modem_available = modem_opened
        }))
        info_file.close()
    end

    -- Initial network announcement
    if modem_opened then
        broadcastPresence()
    end
end

-- Broadcast network presence (local network only)
function broadcastPresence()
    if not rednet.isOpen() then
        return
    end

    local announcement = {
        type = "announce",
        id = cfg.id,
        hostname = cfg.hostname,
        mac = cfg.mac,
        ip = cfg.ipv4,
        services = {},
        timestamp = os.epoch("utc")
    }

    -- Add enabled services
    for service, config in pairs(cfg.services) do
        if config.enabled then
            announcement.services[service] = config.port
        end
    end

    rednet.broadcast(announcement, cfg.discovery_proto)
    logger:debug("Broadcast network presence")
    network_state.stats.packets_sent = network_state.stats.packets_sent + 1
end

-- Handle discovery protocol
local function handleDiscovery(sender, message)
    if message == "whoami?" then
        -- Simple identification response
        local response = {
            id = cfg.id,
            hostname = cfg.hostname,
            mac = cfg.mac,
            ip = cfg.ipv4
        }
        rednet.send(sender, response, cfg.proto)
        logger:trace("Sent identity to computer %d", sender)

    elseif type(message) == "table" and message.type == "query" then
        -- Detailed query response
        local response = {
            type = "response",
            id = cfg.id,
            hostname = cfg.hostname,
            fqdn = cfg.fqdn,
            mac = cfg.mac,
            ip = cfg.ipv4,
            services = {},
            routes = cfg.routes,
            timestamp = os.epoch("utc")
        }

        for service, config in pairs(cfg.services) do
            if config.enabled then
                response.services[service] = config.port
            end
        end

        rednet.send(sender, response, cfg.discovery_proto)
        logger:trace("Sent detailed info to computer %d", sender)

    elseif type(message) == "table" and message.type == "announce" then
        -- Another computer announcing itself
        logger:debug("Computer %d announced: %s (%s)",
                sender, message.hostname or "unknown", message.ip or "unknown")

        -- Update ARP cache
        if message.ip and message.mac then
            network_state.arp_cache[message.ip] = {
                mac = message.mac,
                hostname = message.hostname,
                computer_id = sender,
                expires = os.epoch("utc") + (cfg.cache.arp_ttl * 1000)
            }
        end
    elseif type(message) == "table" and message.type == "id_query" then
        -- Someone asking for computer ID by IP
        if message.ip == cfg.ipv4 then
            local response = {
                type = "id_response",
                ip = cfg.ipv4,
                mac = cfg.mac,
                hostname = cfg.hostname
            }
            rednet.send(sender, response, cfg.discovery_proto)
        end
    end

    network_state.stats.packets_received = network_state.stats.packets_received + 1
end

-- Handle DNS protocol
local function handleDNS(sender, message)
    if type(message) ~= "table" then return end

    if message.type == "query" and message.hostname then
        -- Check if we can answer this query
        if message.hostname == cfg.hostname or
                message.hostname == cfg.fqdn or
                message.hostname == "localhost" then

            local response = {
                type = "response",
                hostname = message.hostname,
                ip = message.hostname == "localhost" and "127.0.0.1" or cfg.ipv4,
                ttl = cfg.cache.dns_ttl
            }

            rednet.send(sender, response, cfg.dns_proto)
            logger:debug("Answered DNS query for %s from computer %d", message.hostname, sender)
        end

        -- Check cache for other hosts
        local cached = network_state.dns_cache[message.hostname]
        if cached and cached.expires > os.epoch("utc") then
            local response = {
                type = "response",
                hostname = message.hostname,
                ip = cached.ip,
                ttl = math.floor((cached.expires - os.epoch("utc")) / 1000)
            }
            rednet.send(sender, response, cfg.dns_proto)
            logger:debug("Answered DNS query from cache: %s -> %s", message.hostname, cached.ip)
        end

    elseif message.type == "response" then
        -- DNS response (cache it)
        if message.hostname and message.ip then
            network_state.dns_cache[message.hostname] = {
                ip = message.ip,
                expires = os.epoch("utc") + ((message.ttl or cfg.cache.dns_ttl) * 1000)
            }
            logger:trace("Cached DNS entry: %s -> %s", message.hostname, message.ip)
        end
    end

    network_state.stats.packets_received = network_state.stats.packets_received + 1
end

-- Handle ARP protocol
local function handleARP(sender, message)
    if type(message) ~= "table" then return end

    if message.type == "request" and message.ip == cfg.ipv4 then
        -- Someone is asking for our MAC
        local response = {
            type = "reply",
            ip = cfg.ipv4,
            mac = cfg.mac,
            hostname = cfg.hostname
        }

        rednet.send(sender, response, cfg.arp_proto)
        logger:debug("Answered ARP request from computer %d", sender)

    elseif message.type == "reply" then
        -- ARP reply (cache it)
        if message.ip and message.mac then
            network_state.arp_cache[message.ip] = {
                mac = message.mac,
                hostname = message.hostname,
                computer_id = sender,
                expires = os.epoch("utc") + (cfg.cache.arp_ttl * 1000)
            }
            logger:trace("Cached ARP entry: %s -> %s (computer %d)",
                    message.ip, message.mac, sender)
        end
    end

    network_state.stats.packets_received = network_state.stats.packets_received + 1
end

-- Handle HTTP protocol (local network)
local function handleHTTP(sender, message)
    if type(message) ~= "table" then return end

    if message.type == "request" or message.type == "http_request" then
        -- HTTP request packet
        local server = network_state.servers[message.port]
        local response

        if server and server.handler then
            -- We have a server on this port
            logger:debug("HTTP %s request from %s to port %d: %s",
                    message.method, message.source and message.source.ip or "unknown",
                    message.port, message.path)

            -- Call the handler
            local success, result = pcall(server.handler, message)
            if success then
                response = result
            else
                logger:error("HTTP handler error: %s", result)
                response = {
                    code = 500,
                    body = "Internal Server Error",
                    headers = {}
                }
            end
        else
            -- No server on this port
            response = {
                code = 404,
                body = "Not Found",
                headers = {}
            }
        end

        -- Send response
        local responsePacket = {
            type = "response",
            id = message.id,
            code = response.code or 200,
            headers = response.headers or {},
            body = response.body or "",
            timestamp = os.epoch("utc")
        }

        rednet.send(sender, responsePacket, cfg.http_proto)
        network_state.stats.packets_sent = network_state.stats.packets_sent + 1

    elseif message.type == "response" or message.type == "http_response" then
        -- HTTP response packet (handled by client)
        logger:trace("HTTP response %d from computer %d", message.code or 0, sender)
    end

    network_state.stats.packets_received = network_state.stats.packets_received + 1
end

-- Handle WebSocket protocol (local network)
local function handleWebSocket(sender, message)
    if type(message) ~= "table" then return end

    if message.type == "connect" or message.type == "ws_connect" then
        -- WebSocket connection request
        local server = network_state.servers[message.url and message.url.port or 8080]

        if server and server.ws_handler then
            -- Accept connection
            local response = {
                type = "accept",
                connectionId = message.connectionId,
                timestamp = os.epoch("utc")
            }

            rednet.send(sender, response, cfg.ws_proto)

            -- Store connection
            network_state.connections[message.connectionId] = {
                id = message.connectionId,
                peer = sender,
                established = os.epoch("utc"),
                lastActivity = os.epoch("utc")
            }

            logger:info("WebSocket connection %s established with computer %d",
                    message.connectionId, sender)
        else
            -- Reject connection
            local response = {
                type = "reject",
                connectionId = message.connectionId,
                reason = "No WebSocket server on port"
            }

            rednet.send(sender, response, cfg.ws_proto)
        end

    elseif message.type == "data" or message.type == "ws_data" then
        -- WebSocket data packet
        local conn = network_state.connections[message.connectionId]
        if conn then
            conn.lastActivity = os.epoch("utc")
            logger:trace("WebSocket data on connection %s", message.connectionId)
        end

    elseif message.type == "close" or message.type == "ws_close" then
        -- WebSocket close
        local conn = network_state.connections[message.connectionId]
        if conn then
            network_state.connections[message.connectionId] = nil
            logger:info("WebSocket connection %s closed", message.connectionId)
        end
    end

    network_state.stats.packets_received = network_state.stats.packets_received + 1
end

-- Handle network adapter protocol messages
local function handleNetworkAdapter(sender, message, protocol)
    if protocol == "network_adapter_discovery" then
        if message.type == "hostname_query" and
                (message.hostname == cfg.hostname or message.hostname == cfg.fqdn) then
            rednet.send(sender, {
                type = "hostname_response",
                hostname = cfg.hostname,
                ip = cfg.ipv4
            }, "network_adapter_discovery")

        elseif message.type == "ip_query" and message.ip == cfg.ipv4 then
            rednet.send(sender, {
                type = "ip_response",
                ip = cfg.ipv4,
                hostname = cfg.hostname
            }, "network_adapter_discovery")
        end

    elseif protocol == "network_adapter_http" then
        handleHTTP(sender, message)

    elseif protocol == "network_adapter_ws" then
        handleWebSocket(sender, message)
    end
end

-- Handle ping protocol (ICMP-like)
local function handlePing(sender, message)
    if type(message) == "table" then
        if message.type == "ping" and message.source then
            -- Someone is pinging us, send pong
            local response = {
                type = "pong",
                seq = message.seq,
                timestamp = message.timestamp,
                source = cfg.ipv4
            }

            rednet.send(sender, response, "pong_" .. message.source)
            logger:trace("Responded to ping from %s", message.source)
        end
    end
end

-- Cleanup expired cache entries
local function cleanupCache()
    local now = os.epoch("utc")
    local cleaned = 0

    -- Clean DNS cache
    for hostname, entry in pairs(network_state.dns_cache) do
        if entry.expires < now then
            network_state.dns_cache[hostname] = nil
            cleaned = cleaned + 1
            logger:trace("Expired DNS entry: %s", hostname)
        end
    end

    -- Clean ARP cache
    for ip, entry in pairs(network_state.arp_cache) do
        if entry.expires < now then
            network_state.arp_cache[ip] = nil
            cleaned = cleaned + 1
            logger:trace("Expired ARP entry: %s", ip)
        end
    end

    -- Clean stale connections
    for id, conn in pairs(network_state.connections) do
        if (now - conn.lastActivity) > (cfg.advanced.connection_timeout * 1000) then
            network_state.connections[id] = nil
            cleaned = cleaned + 1
            logger:debug("Cleaned up stale connection: %s", id)
        end
    end

    if cleaned > 0 then
        logger:debug("Cleaned %d expired cache entries", cleaned)
    end
end

-- Write statistics
local function writeStats()
    -- Calculate uptime
    network_state.stats.uptime = os.epoch("utc") - network_state.start_time

    local stats_file = fs.open("/var/run/netd.stats", "w")
    if stats_file then
        stats_file.write(textutils.serialize(network_state.stats))
        stats_file.close()
    end
end

-- Main daemon loop
local function mainLoop()
    local next_broadcast = os.epoch("utc") + (cfg.services.discovery.interval * 1000)
    local next_cleanup = os.epoch("utc") + 60000  -- Every minute
    local next_stats = os.epoch("utc") + 10000    -- Every 10 seconds
    local next_save = os.epoch("utc") + 300000    -- Every 5 minutes

    logger:info("Entering main loop")

    while network_state.running do
        local event = {os.pullEvent()}

        if event[1] == "rednet_message" then
            local sender, message, protocol = event[2], event[3], event[4]

            -- Route to appropriate handler
            if protocol == cfg.proto or protocol == cfg.discovery_proto then
                handleDiscovery(sender, message)
            elseif protocol == cfg.dns_proto then
                handleDNS(sender, message)
            elseif protocol == cfg.arp_proto then
                handleARP(sender, message)
            elseif protocol == cfg.http_proto then
                handleHTTP(sender, message)
            elseif protocol == cfg.ws_proto then
                handleWebSocket(sender, message)
            elseif protocol and protocol:match("^ping_") then
                handlePing(sender, message)
            elseif protocol and protocol:match("^network_adapter") then
                handleNetworkAdapter(sender, message, protocol)
            elseif protocol == "network_packet" then
                -- Generic network packet routing
                if type(message) == "table" then
                    if message.type == "http_request" then
                        handleHTTP(sender, message)
                    elseif message.type:match("^ws_") then
                        handleWebSocket(sender, message)
                    end
                end
            end

        elseif event[1] == "timer" then
            local now = os.epoch("utc")

            -- Periodic broadcasts (local network only)
            if cfg.services.discovery.enabled and now >= next_broadcast and rednet.isOpen() then
                broadcastPresence()
                next_broadcast = now + (cfg.services.discovery.interval * 1000)
            end

            -- Cache cleanup
            if now >= next_cleanup then
                cleanupCache()
                next_cleanup = now + 60000
            end

            -- Statistics
            if now >= next_stats then
                writeStats()
                next_stats = now + 10000
            end

            -- Save state
            if now >= next_save then
                saveState()
                next_save = now + 300000
                logger:debug("Saved network state")
            end

        elseif event[1] == "terminate" then
            logger:info("Received termination signal")
            network_state.running = false
        end

        -- Set up timers for next iteration
        os.startTimer(1)
    end
end

-- Shutdown procedure
local function shutdown()
    logger:info("Shutting down %s", daemon_name)

    -- Save final state
    saveState()

    -- Write final statistics
    writeStats()

    -- Close all connections
    for id, conn in pairs(network_state.connections) do
        logger:debug("Closing connection: %s", id)
    end
    network_state.connections = {}

    -- Remove PID file
    if fs.exists("/var/run/netd.pid") then
        fs.delete("/var/run/netd.pid")
    end

    -- Close log file
    if logger.log_file then
        logger.log_file:close()
    end

    -- Unhost from rednet
    if rednet.isOpen() then
        rednet.unhost(cfg.proto)
    end

    logger:info("%s stopped", daemon_name)
end

-- Main execution
local function main()
    -- Initialize
    initNetwork()

    -- Handle termination
    local success, err = pcall(mainLoop)
    if not success then
        logger:error("Main loop error: %s", err)
    end

    -- Cleanup
    shutdown()
end

-- Start the daemon
main()