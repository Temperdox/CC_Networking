-- /bin/netd.lua (with UDP support)
-- Network daemon for ComputerCraft
-- Updated with UDP protocol capabilities

local version, daemon_name = "1.1.0", "netd"
print("[netd] Starting Network Daemon v" .. version .. " (UDP enabled)")

-- already running?
if fs.exists("/var/run/netd.pid") then
    local f = fs.open("/var/run/netd.pid","r"); if f then local pid=f.readAll(); f.close(); print("[netd] Already running (PID: "..pid..")"); return end
end

-- Check for stop signals at startup
if fs.exists("/var/run/netd.stop.all") then
    print("[netd] Global stop signal present - not starting")
    return
end
if fs.exists("/var/run/netd.stop") then
    print("[netd] Stop signal present - cleaning up and not starting")
    fs.delete("/var/run/netd.stop")
    return
end

-- Load UDP protocol if available
local udp = nil
if fs.exists("/protocols/udp.lua") then
    udp = dofile("/protocols/udp.lua")
    print("[netd] UDP protocol loaded")
end

-- load config
local function loadConfig()
    local paths={"/config/network.cfg","/etc/network.cfg"}
    for _,p in ipairs(paths) do
        if fs.exists(p) then
            print("[netd] Loading config from: " .. p)
            local fh=fs.open(p,"r"); if not fh then print("[netd] ERROR: Cannot read: "..p) goto continue end
            local content=fh.readAll(); fh.close()
            local fn,err=loadstring(content); if not fn then print("[netd] ERROR: parse: "..tostring(err)) goto continue end
            local ok,res=pcall(fn); if ok and res then
            print("[netd] Configuration loaded successfully")
            -- Add UDP protocol configuration
            res.udp_proto = res.udp_proto or "ccnet_udp"
            res.services = res.services or {}
            res.services.udp = res.services.udp or { enabled = true, port = 0 }
            return res
        else print("[netd] ERROR: exec: "..tostring(res)) end
        end
        ::continue::
    end
    error("[netd] FATAL: No valid configuration found")
end
local cfg = loadConfig()

-- -------------- logger (quiet + buffered) ----------------
local logger = {
    levels = { trace=1, debug=2, info=3, warn=4, error=5 },
    current_level = 3,                 -- file log threshold
    console_min_level = 4,             -- only warn/error to console
    buffer = {},
    next_flush = os.epoch("utc") + 1000,
    flush_interval_ms = 1000,
    files = {},
}
local function lv(name) return logger.levels[name] or 3 end

function logger:init()
    if not fs.exists("logs") then fs.makeDir("logs") end
    if not fs.exists("/var/log") then fs.makeDir("/var/log") end
    self.files["main"] = fs.open("logs/netd.log","a")

    if cfg.logging and cfg.logging.enabled then
        self.current_level = self.levels[cfg.logging.level] or self.current_level
        local dir = fs.getDir(cfg.logging.file or "")
        if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
        self.files["config"] = fs.open(cfg.logging.file,"a")
    end
    -- lower console noise immediately
    print("[netd] Logger initialized (console warns only)")
end

function logger:enqueue(line)
    table.insert(self.buffer, line)
end

function logger:flush()
    if #self.buffer == 0 then return end
    for _,fh in pairs(self.files) do
        if fh then
            for i=1,#self.buffer do fh.writeLine(self.buffer[i]) end
            fh.flush()
        end
    end
    self.buffer = {}
end

function logger:log(level, fmt, ...)
    local l = lv(level)
    local msg = string.format(fmt, ...)
    local line = string.format("[%s] [%s] %s", os.date("%Y-%m-%d %H:%M:%S"), string.upper(level), msg)

    -- console only for warn/error
    if l >= self.console_min_level then print(line) end
    -- file threshold
    if l >= self.current_level then self:enqueue(line) end
end

function logger:info(...)  self:log("info",  ...) end
function logger:debug(...) self:log("debug", ...) end
function logger:warn(...)  self:log("warn",  ...) end
function logger:error(...) self:log("error", ...) end
function logger:trace(...) self:log("trace", ...) end

function logger:close()
    self:flush()
    for _,fh in pairs(self.files) do if fh then fh.close() end end
    self.files = {}
end

logger:init()

-- ----------------- network state ----------------
local network_state = {
    running = true,
    start_time = os.epoch("utc"),
    dns_cache = {},
    arp_cache = {},
    connections = {},
    servers = {},
    udp_sockets = {},  -- Track UDP sockets
    stats = {
        packets_sent = 0,
        packets_received = 0,
        bytes_sent = 0,
        bytes_received = 0,
        dns_queries = 0,
        arp_requests = 0,
        http_requests = 0,
        websocket_connections = 0,
        udp_packets = 0,  -- Add UDP statistics
        uptime = 0
    }
}

-- ----------------- Existing helper functions ----------------
local function loadState()
    if not fs.exists("/var/cache/netd.state") then return end
    local f = fs.open("/var/cache/netd.state","r"); if not f then return end
    local s = textutils.unserialize(f.readAll()); f.close()
    if s then
        network_state.dns_cache = s.dns_cache or {}
        network_state.arp_cache = s.arp_cache or {}
        network_state.servers = s.servers or {}
        network_state.udp_sockets = s.udp_sockets or {}
        logger:debug("Loaded network state from cache")
    end
end

local function saveState()
    local f = fs.open("/var/cache/netd.state","w"); if f then
        f.write(textutils.serialize({
            dns_cache = network_state.dns_cache,
            arp_cache = network_state.arp_cache,
            servers = network_state.servers,
            udp_sockets = network_state.udp_sockets,
            saved_at = os.epoch("utc")
        }))
        f.close()
    end
end

local function openModem()
    if cfg.modem_side and peripheral.isPresent(cfg.modem_side) then
        rednet.open(cfg.modem_side); logger:info("Modem opened on configured side: %s", cfg.modem_side); return true
    end
    local sides={"back","top","bottom","left","right","front"}; for _,s in ipairs(sides) do
        if peripheral.isPresent(s) and peripheral.getType(s)=="modem" then
            rednet.open(s); cfg.modem_side = s; logger:info("Modem opened on side: %s", cfg.modem_side); return true
        end
    end
    logger:warn("No modem found - network features disabled"); return false
end

local function initNetwork()
    logger:info("Starting %s v%s", daemon_name, version)
    logger:info("Computer ID: %d, Hostname: %s", cfg.id, cfg.hostname)
    logger:info("MAC: %s, IP: %s", cfg.mac, cfg.ipv4)

    loadState()
    local modem = openModem()
    if modem then rednet.host(cfg.proto, cfg.hostname); logger:debug("Registered hostname: %s", cfg.hostname) end

    local dirs={"/var","/var/run","/var/cache","/var/log"}; for _,d in ipairs(dirs) do if not fs.exists(d) then fs.makeDir(d) end end

    local pid = fs.open("/var/run/netd.pid","w"); if pid then pid.write(tostring(cfg.id)); pid.close(); logger:info("Created PID file") end

    local info = fs.open("/var/run/network.info","w"); if info then
        info.write(textutils.serialize({
            ip=cfg.ipv4,
            mac=cfg.mac,
            hostname=cfg.hostname,
            fqdn=cfg.fqdn,
            gateway=cfg.gateway,
            dns=cfg.dns,
            modem_available=modem,
            udp_enabled = udp ~= nil
        }))
        info.close(); logger:debug("Created network info file")
    end

    -- Initialize UDP if available
    if udp then
        udp.start()
        logger:info("UDP protocol initialized")
    end

    if modem then broadcastPresence() end
    return modem
end

function broadcastPresence()
    if not rednet.isOpen() then return end
    local ann={
        type="announce",
        id=cfg.id,
        hostname=cfg.hostname,
        mac=cfg.mac,
        ip=cfg.ipv4,
        services={},
        timestamp=os.epoch("utc"),
        protocols={
            udp = udp ~= nil
        }
    }
    if cfg.services then for s,c in pairs(cfg.services) do if c.enabled then ann.services[s]=c.port end end end
    rednet.broadcast(ann, cfg.discovery_proto)
    logger:debug("Broadcast network presence (UDP: %s)", tostring(udp ~= nil))
    network_state.stats.packets_sent = network_state.stats.packets_sent + 1
end

-- ----------------- UDP Handler ----------------
local function handleUDP(sender, message)
    if not udp then
        logger:warn("Received UDP packet but UDP protocol not loaded")
        return
    end

    if type(message) ~= "table" then return end

    network_state.stats.udp_packets = network_state.stats.udp_packets + 1

    -- Pass to UDP protocol handler
    local handled = udp.handleIncomingPacket(message)

    if handled then
        logger:trace("UDP packet handled from %d", sender)
        network_state.stats.packets_received = network_state.stats.packets_received + 1
        network_state.stats.bytes_received = network_state.stats.bytes_received + #textutils.serialize(message)
    else
        logger:debug("UDP packet not handled - port %d unreachable", message.udp_packet and message.udp_packet.dest_port or 0)
    end
end

-- ----------------- Existing handlers (discovery, DNS, ARP, HTTP, WS) ----------------
local function handleDiscovery(sender,message)
    if message=="whoami?" then
        rednet.send(sender,{id=cfg.id,hostname=cfg.hostname,mac=cfg.mac,ip=cfg.ipv4}, cfg.proto); logger:trace("Sent identity to computer %d", sender)
    elseif type(message)=="table" and message.type=="query" then
        local resp={ type="response", id=cfg.id, hostname=cfg.hostname, fqdn=cfg.fqdn, mac=cfg.mac, ip=cfg.ipv4, services={}, routes=cfg.routes, timestamp=os.epoch("utc"), protocols={udp=udp~=nil} }
        if cfg.services then for s,c in pairs(cfg.services) do if c.enabled then resp.services[s]=c.port end end end
        rednet.send(sender, resp, cfg.discovery_proto); logger:trace("Sent detailed info to computer %d", sender)
    elseif type(message)=="table" and message.type=="announce" then
        logger:debug("Computer %d announced: %s (%s)", sender, message.hostname or "unknown", message.ip or "unknown")
        if message.ip and message.mac and cfg.cache then
            network_state.arp_cache[message.ip] = { mac=message.mac, hostname=message.hostname, computer_id=sender, expires=os.epoch("utc") + (cfg.cache.arp_ttl*1000) }
        end
    elseif type(message)=="table" and message.type=="id_query" then
        if message.ip == cfg.ipv4 then rednet.send(sender,{type="id_response", ip=cfg.ipv4, mac=cfg.mac, hostname=cfg.hostname}, cfg.discovery_proto) end
    end
    network_state.stats.packets_received = network_state.stats.packets_received + 1
end

local function handleDNS(sender,message)
    if type(message) ~= "table" then return end
    network_state.stats.dns_queries = network_state.stats.dns_queries + 1
    if message.type=="query" and message.hostname then
        if message.hostname==cfg.hostname or message.hostname==cfg.fqdn or message.hostname=="localhost" then
            local resp={ type="response", hostname=message.hostname, ip=(message.hostname=="localhost" and "127.0.0.1" or cfg.ipv4), ttl=(cfg.cache and cfg.cache.dns_ttl or 300) }
            rednet.send(sender, resp, cfg.dns_proto); logger:debug("Answered DNS query for %s from %d", message.hostname, sender)
        end
        local cached = network_state.dns_cache[message.hostname]
        if cached and cached.expires > os.epoch("utc") then
            rednet.send(sender, {type="response", hostname=message.hostname, ip=cached.ip, ttl=cached.ttl}, cfg.dns_proto)
            logger:trace("Sent cached DNS response for %s", message.hostname)
        end
    elseif message.type=="response" and message.hostname and message.ip then
        network_state.dns_cache[message.hostname] = { ip=message.ip, ttl=message.ttl or 300, expires=os.epoch("utc") + ((message.ttl or 300)*1000) }
        logger:debug("Cached DNS response: %s -> %s", message.hostname, message.ip)
    end
    network_state.stats.packets_received = network_state.stats.packets_received + 1
end

local function handleARP(sender,message)
    if type(message) ~= "table" then return end
    network_state.stats.arp_requests = network_state.stats.arp_requests + 1
    if message.type=="request" and message.target_ip==cfg.ipv4 then
        rednet.send(sender,{type="reply", ip=cfg.ipv4, mac=cfg.mac}, cfg.arp_proto)
        logger:trace("Sent ARP reply to %d", sender)
    elseif message.type=="reply" and message.ip and message.mac then
        network_state.arp_cache[message.ip] = { mac=message.mac, computer_id=sender, expires=os.epoch("utc") + (cfg.cache and cfg.cache.arp_ttl*1000 or 600000) }
        logger:debug("Cached ARP: %s -> %s", message.ip, message.mac)
    end
    network_state.stats.packets_received = network_state.stats.packets_received + 1
end

local function handleHTTP(sender,message)
    if type(message) ~= "table" then return end
    network_state.stats.http_requests = network_state.stats.http_requests + 1
    if message.type=="request" or message.type=="http_request" then
        logger:debug("HTTP request from %d: %s %s", sender, message.method or "GET", message.path or "/")
        local response
        local server = network_state.servers[message.port or 80]
        if server and server.handler then
            local req={ method=message.method or "GET", path=message.path or "/", headers=message.headers or {}, body=message.body, source=sender }
            local ok,res = pcall(server.handler, req); if ok then response=res else logger:error("HTTP handler error: %s", res); response={code=500, body="Internal Server Error", headers={}} end
        else
            response={code=404, body="Not Found", headers={}}
        end
        local pkt={ type="response", id=message.id, code=response.code or 200, headers=response.headers or {}, body=response.body or "", timestamp=os.epoch("utc") }
        rednet.send(sender, pkt, cfg.http_proto);
        network_state.stats.packets_sent = network_state.stats.packets_sent + 1
        network_state.stats.bytes_sent = network_state.stats.bytes_sent + #textutils.serialize(pkt)
    elseif message.type=="response" or message.type=="http_response" then
        logger:trace("HTTP response %d from %d", message.code or 0, sender)
    end
    network_state.stats.packets_received = network_state.stats.packets_received + 1
    network_state.stats.bytes_received = network_state.stats.bytes_received + #textutils.serialize(message)
end

local function handleWebSocket(sender,message)
    if type(message) ~= "table" then return end
    if message.type=="connect" or message.type=="ws_connect" then
        network_state.stats.websocket_connections = network_state.stats.websocket_connections + 1
        local server = network_state.servers[message.url and message.url.port or 8080]
        if server and server.ws_handler then
            rednet.send(sender,{type="accept", connectionId=message.connectionId, timestamp=os.epoch("utc")}, cfg.ws_proto)
            network_state.connections[message.connectionId]={ id=message.connectionId, peer=sender, established=os.epoch("utc"), lastActivity=os.epoch("utc") }
            logger:info("WebSocket connection %s established with %d", message.connectionId, sender)
        else
            rednet.send(sender,{type="reject", connectionId=message.connectionId, reason="No WebSocket server on port"}, cfg.ws_proto)
        end
    elseif message.type=="data" or message.type=="ws_data" then
        local c=network_state.connections[message.connectionId]; if c then c.lastActivity=os.epoch("utc"); logger:trace("WS data %s", message.connectionId) end
    elseif message.type=="close" or message.type=="ws_close" then
        if network_state.connections[message.connectionId] then network_state.connections[message.connectionId]=nil; logger:info("WebSocket %s closed", message.connectionId) end
    end
    network_state.stats.packets_received = network_state.stats.packets_received + 1
end

local function handleNetworkAdapter(sender,message,protocol)
    if protocol=="network_adapter_discovery" then
        if message.type=="hostname_query" and (message.hostname==cfg.hostname or message.hostname==cfg.fqdn) then
            rednet.send(sender,{type="hostname_response", hostname=cfg.hostname, ip=cfg.ipv4}, "network_adapter_discovery")
        elseif message.type=="ip_query" and message.ip==cfg.ipv4 then
            rednet.send(sender,{type="ip_response", ip=cfg.ipv4, hostname=cfg.hostname}, "network_adapter_discovery")
        end
    elseif protocol=="network_adapter_http" then handleHTTP(sender,message)
    elseif protocol=="network_adapter_ws" then handleWebSocket(sender,message)
    elseif protocol=="network_adapter_udp" then handleUDP(sender,message) end
end

local function handlePing(sender,message)
    if type(message)=="table" and message.type=="ping" and message.source then
        rednet.send(sender,{type="pong", seq=message.seq, timestamp=message.timestamp, source=cfg.ipv4}, "pong_"..message.source)
        logger:trace("Responded to ping from %s", message.source)
    end
end

local function cleanupCache()
    local now=os.epoch("utc"); local cleaned=0
    for h,e in pairs(network_state.dns_cache) do if e.expires<now then network_state.dns_cache[h]=nil; cleaned=cleaned+1 end end
    for ip,e in pairs(network_state.arp_cache) do if e.expires<now then network_state.arp_cache[ip]=nil; cleaned=cleaned+1 end end
    for id,c in pairs(network_state.connections) do local to=(cfg.advanced and cfg.advanced.connection_timeout or 30)*1000; if (now-c.lastActivity)>to then network_state.connections[id]=nil; cleaned=cleaned+1 end end
    -- Cleanup inactive UDP sockets
    for port,socket in pairs(network_state.udp_sockets) do
        if socket.expires and socket.expires < now then
            network_state.udp_sockets[port] = nil
            cleaned = cleaned + 1
            logger:debug("Cleaned up expired UDP socket on port %d", port)
        end
    end
    if cleaned>0 then logger:debug("Cleaned %d expired cache entries", cleaned) end
end

local function writeStats()
    network_state.stats.uptime = os.epoch("utc") - network_state.start_time
    -- Include UDP stats if available
    if udp then
        local udpStats = udp.getStatistics()
        network_state.stats.udp_details = udpStats
    end
    local f=fs.open("/var/run/netd.stats","w"); if f then f.write(textutils.serialize(network_state.stats)); f.close() end
end

local function mainLoop()
    local next_bcast = os.epoch("utc") + ((cfg.services and cfg.services.discovery and cfg.services.discovery.interval or 30)*1000)
    local next_cleanup = os.epoch("utc") + 60000
    local next_stats = os.epoch("utc") + 10000
    local next_save = os.epoch("utc") + 300000

    logger:info("Entering main loop")
    local tick = os.startTimer(1)

    while network_state.running do
        -- Check for stop signals at the beginning of each loop iteration
        if fs.exists("/var/run/netd.stop.all") then
            logger:warn("Global stop signal detected - shutting down")
            network_state.running = false
            -- Don't delete the file here, let watchdog clean it up
            break
        end

        if fs.exists("/var/run/netd.stop") then
            logger:info("Stop signal detected - shutting down")
            network_state.running = false
            fs.delete("/var/run/netd.stop")
            break
        end

        local ev = { os.pullEvent() }
        if ev[1]=="rednet_message" then
            local sender,msg,proto = ev[2], ev[3], ev[4]
            if proto==cfg.proto or proto==cfg.discovery_proto then handleDiscovery(sender,msg)
            elseif proto==cfg.dns_proto then handleDNS(sender,msg)
            elseif proto==cfg.arp_proto then handleARP(sender,msg)
            elseif proto==cfg.http_proto then handleHTTP(sender,msg)
            elseif proto==cfg.ws_proto then handleWebSocket(sender,msg)
            elseif proto==cfg.udp_proto or proto=="UDP_PACKET" then handleUDP(sender,msg)
            elseif proto and proto:match("^ping_") then handlePing(sender,msg)
            elseif proto and proto:match("^network_adapter") then handleNetworkAdapter(sender,msg,proto)
            elseif proto=="network_packet" and type(msg)=="table" then
                if msg.type=="http_request" then handleHTTP(sender,msg)
                elseif msg.type and msg.type:match("^%w*ws_%w+") then handleWebSocket(sender,msg)
                elseif msg.protocol == "UDP" then handleUDP(sender,msg) end
            end
        elseif ev[1]=="udp_packet" and udp then
            -- Handle UDP packet events from the UDP protocol
            local port, packet = ev[2], ev[3]
            if network_state.udp_sockets[port] then
                network_state.udp_sockets[port].lastActivity = os.epoch("utc")
            end

        elseif ev[1]=="timer" then
            if ev[2]==tick then
                local now=os.epoch("utc")

                -- Periodic check for stop signals
                if now % 5000 < 1000 then  -- Check every 5 seconds
                    if fs.exists("/var/run/netd.stop.all") or fs.exists("/var/run/netd.stop") then
                        logger:info("Stop signal detected during timer check")
                        network_state.running = false
                    end
                end

                if cfg.services and cfg.services.discovery and cfg.services.discovery.enabled and rednet.isOpen() and now>=next_bcast then
                    broadcastPresence(); next_bcast = now + (cfg.services.discovery.interval*1000)
                end
                if now>=next_cleanup then cleanupCache(); next_cleanup = now + 60000 end
                if now>=next_stats then writeStats(); next_stats = now + 10000 end
                if now>=next_save then saveState(); next_save = now + 300000; logger:debug("Saved network state") end
                -- periodic log flush
                if now >= logger.next_flush then logger:flush(); logger.next_flush = now + logger.flush_interval_ms end
                tick = os.startTimer(1)
            end
        elseif ev[1]=="terminate" then
            logger:info("Received termination signal")
            network_state.running=false
        end
    end
end

local function shutdown()
    logger:info("Shutting down %s", daemon_name)

    -- Shutdown UDP if available
    if udp then
        udp.stop()
        logger:info("UDP protocol stopped")
    end

    saveState(); writeStats()
    for id,_ in pairs(network_state.connections) do logger:debug("Closing connection: %s", id) end
    network_state.connections={}
    if fs.exists("/var/run/netd.pid") then fs.delete("/var/run/netd.pid") end
    if rednet.isOpen() then rednet.unhost(cfg.proto) end
    logger:close()
    print("[netd] stopped")
end

local function main()
    local modem = initNetwork()
    if modem then logger:info("Network daemon ready with full functionality (UDP enabled: %s)", tostring(udp ~= nil))
    else logger:warn("Network daemon ready with limited functionality (no modem)") end

    local ok,err = pcall(mainLoop)
    if not ok then logger:error("Main loop error: %s", err) end
    shutdown()
end

-- Register UDP as global for other protocols to use
if udp then
    _G.netd_udp = udp
end

main()