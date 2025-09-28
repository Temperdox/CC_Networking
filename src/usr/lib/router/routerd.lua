-- /usr/lib/router/routerd.lua
-- Main router daemon for ComputerCraft
-- Handles routing, NAT, firewall, DHCP, and wireless

local DAEMON_VERSION = "2.0.0"

-- Load configuration
local function loadConfig()
    local path = "/etc/router.cfg"
    if not fs.exists(path) then
        error("Router configuration not found!")
    end

    local file = fs.open(path, "r")
    local content = file.readAll()
    file.close()

    local func = loadstring(content)
    if not func then
        error("Invalid router configuration!")
    end

    return func()
end

-- Load firewall rules
local function loadFirewallRules()
    local path = "/etc/firewall.rules"
    if not fs.exists(path) then
        return nil
    end

    local file = fs.open(path, "r")
    local content = file.readAll()
    file.close()

    local func = loadstring(content)
    if func then
        return func()
    end
    return nil
end

-- Router daemon class
local RouterDaemon = {}
RouterDaemon.__index = RouterDaemon

function RouterDaemon:new(config)
    local obj = {
        config = config,
        running = true,
        interfaces = {},
        routing_table = {},
        arp_table = {},
        nat_table = {},
        connection_tracking = {},
        dhcp_leases = {},
        wireless_clients = {},
        firewall_rules = nil,
        statistics = {
            packets_forwarded = 0,
            packets_dropped = 0,
            packets_nat = 0,
            bytes_rx = 0,
            bytes_tx = 0,
            uptime_start = os.epoch("utc")
        }
    }

    setmetatable(obj, self)
    return obj
end

function RouterDaemon:init()
    print("[RouterD] Initializing Router Daemon v" .. DAEMON_VERSION)

    -- Load firewall rules
    self.firewall_rules = loadFirewallRules()

    -- Initialize interfaces
    self:initInterfaces()

    -- Initialize routing table
    self:initRoutingTable()

    -- Start services
    if self.config.lan.dhcp.enabled then
        self:startDHCPServer()
    end

    if self.config.services.dns.enabled then
        self:startDNSServer()
    end

    if self.config.wireless.enabled then
        self:startWirelessAP()
    end

    if self.config.services.web_admin.enabled then
        self:startWebAdmin()
    end

    -- Write PID file
    local pidFile = fs.open("/var/run/routerd.pid", "w")
    if pidFile then
        pidFile.write(tostring(os.getComputerID()))
        pidFile.close()
    end

    print("[RouterD] Router initialized successfully")
end

function RouterDaemon:initInterfaces()
    local sides = {"top", "bottom", "left", "right", "front", "back"}

    for _, side in ipairs(sides) do
        if peripheral.isPresent(side) then
            local pType = peripheral.getType(side)
            if pType == "modem" then
                local modem = peripheral.wrap(side)
                local isWireless = modem.isWireless and modem.isWireless()

                -- Open modem
                modem.open(os.getComputerID())
                modem.open(65535) -- Broadcast channel

                -- Assign to interface
                if isWireless and self.config.wireless.enabled then
                    self.interfaces.wlan0 = {
                        modem = modem,
                        side = side,
                        type = "wireless",
                        ip = self.config.lan.ip,
                        netmask = self.config.lan.netmask
                    }
                    print("[RouterD] Wireless interface initialized on " .. side)
                else
                    -- Determine if LAN or WAN
                    if not self.interfaces.eth0 then
                        self.interfaces.eth0 = {
                            modem = modem,
                            side = side,
                            type = "wired",
                            ip = self.config.lan.ip,
                            netmask = self.config.lan.netmask
                        }
                        print("[RouterD] LAN interface initialized on " .. side)
                    elseif not self.interfaces.eth1 then
                        self.interfaces.eth1 = {
                            modem = modem,
                            side = side,
                            type = "wired",
                            ip = self.config.wan.ip or "0.0.0.0",
                            netmask = self.config.wan.netmask or "255.255.255.0"
                        }
                        print("[RouterD] WAN interface initialized on " .. side)
                    end
                end
            end
        end
    end

    -- Setup rednet for routing
    if self.interfaces.eth0 then
        rednet.open(self.interfaces.eth0.side)
        rednet.host("router", self.config.hostname)
    end
end

function RouterDaemon:initRoutingTable()
    -- Default routes
    self.routing_table = {
        -- LAN route
        {
            destination = "192.168.1.0",
            netmask = "255.255.255.0",
            gateway = "0.0.0.0",
            interface = "eth0",
            metric = 0
        },
        -- Default route (WAN)
        {
            destination = "0.0.0.0",
            netmask = "0.0.0.0",
            gateway = self.config.wan.gateway or "0.0.0.0",
            interface = "eth1",
            metric = 100
        }
    }
end

function RouterDaemon:startDHCPServer()
    print("[RouterD] Starting DHCP server...")

    -- Initialize DHCP lease pool
    local start_ip = self.config.lan.dhcp.start
    local end_ip = self.config.lan.dhcp["end"]

    -- Parse IP ranges
    local start_parts = {}
    for part in start_ip:gmatch("(%d+)") do
        table.insert(start_parts, tonumber(part))
    end

    local end_parts = {}
    for part in end_ip:gmatch("(%d+)") do
        table.insert(end_parts, tonumber(part))
    end

    -- Generate available IPs
    self.dhcp_pool = {}
    for i = start_parts[4], end_parts[4] do
        local ip = string.format("%d.%d.%d.%d",
                start_parts[1], start_parts[2], start_parts[3], i)
        table.insert(self.dhcp_pool, {
            ip = ip,
            available = true
        })
    end

    print("[RouterD] DHCP pool: " .. start_ip .. " - " .. end_ip)
end

function RouterDaemon:startDNSServer()
    print("[RouterD] Starting DNS server...")

    -- DNS cache
    self.dns_cache = {}

    -- Local DNS records
    self.dns_records = {
        ["router.local"] = self.config.lan.ip,
        [self.config.hostname .. ".local"] = self.config.lan.ip
    }
end

function RouterDaemon:startWirelessAP()
    print("[RouterD] Starting Wireless Access Point...")
    print("[RouterD] SSID: " .. self.config.wireless.ssid)
    print("[RouterD] Security: " .. self.config.wireless.security)

    -- Initialize wireless encryption
    if self.config.wireless.security == "WPA3" then
        self:initWPA3()
    elseif self.config.wireless.security == "WPA2" then
        self:initWPA2()
    end

    -- Broadcast beacon frames
    self.beacon_timer = os.startTimer(0.1) -- Beacon every 100ms
end

function RouterDaemon:initWPA3()
    -- Simplified WPA3 implementation for ComputerCraft
    -- In reality, this would implement SAE (Simultaneous Authentication of Equals)

    -- Generate PMK from password
    self.wireless_pmk = self:generatePMK(
            self.config.wireless.password,
            self.config.wireless.ssid
    )

    print("[RouterD] WPA3 initialized")
end

function RouterDaemon:generatePMK(password, ssid)
    -- Simplified PBKDF2 for ComputerCraft
    local iterations = 4096
    local hash = password .. ssid

    for i = 1, iterations do
        -- Simple hash iteration
        local sum = 0
        for j = 1, #hash do
            sum = sum + string.byte(hash, j) * i
        end
        hash = tostring(sum)
    end

    return hash
end

function RouterDaemon:startWebAdmin()
    print("[RouterD] Starting Web Admin on port " .. self.config.services.web_admin.port)

    -- Web admin will be handled in a separate coroutine
    self.web_admin_enabled = true
end

function RouterDaemon:handlePacket(interface, packet, sender)
    -- Update statistics
    self.statistics.bytes_rx = self.statistics.bytes_rx + #textutils.serialize(packet)

    -- Apply firewall rules
    if self.config.firewall.enabled then
        local action = self:applyFirewallRules(packet, interface, "INPUT")
        if action == "DROP" then
            self.statistics.packets_dropped = self.statistics.packets_dropped + 1
            return
        end
    end

    -- Check if packet is for us or needs forwarding
    if packet.destination == self.config.lan.ip or
            packet.destination == self.config.wan.ip then
        -- Process locally
        self:processLocalPacket(packet, sender, interface)
    else
        -- Forward packet
        self:forwardPacket(packet, sender, interface)
    end
end

function RouterDaemon:applyFirewallRules(packet, interface, chain)
    if not self.firewall_rules then
        return "ACCEPT"
    end

    local rules = self.firewall_rules.chains[chain] or {}

    for _, rule in ipairs(rules) do
        local match = true

        -- Check conditions
        if rule.interface and rule.interface ~= interface then
            match = false
        end

        if rule.source and not self:matchIP(packet.source, rule.source) then
            match = false
        end

        if rule.destination and not self:matchIP(packet.destination, rule.destination) then
            match = false
        end

        if rule.protocol and packet.protocol ~= rule.protocol then
            match = false
        end

        if rule.dport and packet.dport ~= rule.dport then
            match = false
        end

        if rule.sport and packet.sport ~= rule.sport then
            match = false
        end

        if match then
            return rule.action
        end
    end

    -- Return default policy
    return self.firewall_rules.policies[chain] or "ACCEPT"
end

function RouterDaemon:matchIP(ip, pattern)
    if pattern:find("/") then
        -- CIDR notation
        local network, bits = pattern:match("([%d%.]+)/(%d+)")
        return self:inNetwork(ip, network, bits)
    else
        return ip == pattern
    end
end

function RouterDaemon:inNetwork(ip, network, bits)
    -- Simplified network matching
    local ip_parts = {}
    for part in ip:gmatch("(%d+)") do
        table.insert(ip_parts, tonumber(part))
    end

    local net_parts = {}
    for part in network:gmatch("(%d+)") do
        table.insert(net_parts, tonumber(part))
    end

    local bytes = math.floor(tonumber(bits) / 8)

    for i = 1, bytes do
        if ip_parts[i] ~= net_parts[i] then
            return false
        end
    end

    return true
end

function RouterDaemon:processLocalPacket(packet, sender, interface)
    -- Handle packets destined for the router itself

    if packet.type == "DHCP" then
        self:handleDHCP(packet, sender, interface)
    elseif packet.type == "DNS" then
        self:handleDNS(packet, sender, interface)
    elseif packet.type == "HTTP" and packet.dport == self.config.services.web_admin.port then
        self:handleWebAdmin(packet, sender, interface)
    elseif packet.type == "WIRELESS_AUTH" then
        self:handleWirelessAuth(packet, sender, interface)
    end
end

function RouterDaemon:forwardPacket(packet, sender, interface)
    -- Apply firewall rules for forwarding
    if self.config.firewall.enabled then
        local action = self:applyFirewallRules(packet, interface, "FORWARD")
        if action == "DROP" then
            self.statistics.packets_dropped = self.statistics.packets_dropped + 1
            return
        end
    end

    -- Find route
    local route = self:findRoute(packet.destination)
    if not route then
        self.statistics.packets_dropped = self.statistics.packets_dropped + 1
        return
    end

    -- Apply NAT if needed
    if self.config.firewall.nat_enabled and interface == "eth0" then
        packet = self:applyNAT(packet, "SNAT")
        self.statistics.packets_nat = self.statistics.packets_nat + 1
    elseif self.config.firewall.nat_enabled and interface == "eth1" then
        packet = self:applyNAT(packet, "DNAT")
    end

    -- Forward packet
    local out_interface = self.interfaces[route.interface]
    if out_interface then
        if out_interface.modem then
            out_interface.modem.transmit(65535, os.getComputerID(), packet)
            self.statistics.packets_forwarded = self.statistics.packets_forwarded + 1
            self.statistics.bytes_tx = self.statistics.bytes_tx + #textutils.serialize(packet)
        end
    end
end

function RouterDaemon:findRoute(destination)
    for _, route in ipairs(self.routing_table) do
        if self:inNetwork(destination, route.destination,
                route.netmask == "255.255.255.0" and "24" or "0") then
            return route
        end
    end
    return nil
end

function RouterDaemon:applyNAT(packet, direction)
    if direction == "SNAT" then
        -- Source NAT (masquerading)
        local conn_id = packet.source .. ":" .. packet.sport
        self.nat_table[conn_id] = {
            original_source = packet.source,
            original_sport = packet.sport,
            translated_source = self.config.wan.ip or "10.0.0.1",
            translated_sport = math.random(32768, 65535),
            timestamp = os.epoch("utc")
        }

        packet.source = self.nat_table[conn_id].translated_source
        packet.sport = self.nat_table[conn_id].translated_sport

    elseif direction == "DNAT" then
        -- Destination NAT (port forwarding)
        for _, forward in ipairs(self.config.firewall.port_forwards or {}) do
            if packet.dport == forward.external_port and
                    packet.protocol == forward.protocol then
                packet.destination = forward.internal_ip
                packet.dport = forward.internal_port
                break
            end
        end

        -- Check DMZ
        if self.config.firewall.dmz_host and
                packet.destination == (self.config.wan.ip or "10.0.0.1") then
            packet.destination = self.config.firewall.dmz_host
        end
    end

    return packet
end

function RouterDaemon:handleDHCP(packet, sender, interface)
    if packet.dhcp_type == "DISCOVER" then
        -- Find available IP
        local lease_ip = nil
        for _, ip_entry in ipairs(self.dhcp_pool) do
            if ip_entry.available then
                lease_ip = ip_entry.ip
                ip_entry.available = false
                break
            end
        end

        if lease_ip then
            -- Send DHCP OFFER
            local offer = {
                type = "DHCP",
                dhcp_type = "OFFER",
                client_mac = packet.client_mac,
                offered_ip = lease_ip,
                server_ip = self.config.lan.ip,
                gateway = self.config.lan.ip,
                netmask = self.config.lan.netmask,
                dns = self.config.lan.dhcp.dns,
                lease_time = self.config.lan.dhcp.lease_time
            }

            self.interfaces[interface].modem.transmit(
                    sender, os.getComputerID(), offer
            )
        end

    elseif packet.dhcp_type == "REQUEST" then
        -- Confirm lease
        local lease = {
            client_mac = packet.client_mac,
            ip = packet.requested_ip,
            expires = os.epoch("utc") + (self.config.lan.dhcp.lease_time * 1000),
            hostname = packet.hostname
        }

        self.dhcp_leases[packet.client_mac] = lease

        -- Send DHCP ACK
        local ack = {
            type = "DHCP",
            dhcp_type = "ACK",
            client_mac = packet.client_mac,
            assigned_ip = packet.requested_ip,
            server_ip = self.config.lan.ip,
            gateway = self.config.lan.ip,
            netmask = self.config.lan.netmask,
            dns = self.config.lan.dhcp.dns,
            lease_time = self.config.lan.dhcp.lease_time
        }

        self.interfaces[interface].modem.transmit(
                sender, os.getComputerID(), ack
        )

        -- Save lease to file
        self:saveDHCPLeases()
    end
end

function RouterDaemon:handleDNS(packet, sender, interface)
    local response = {
        type = "DNS",
        query_id = packet.query_id,
        answers = {}
    }

    -- Check local records
    if self.dns_records[packet.query] then
        table.insert(response.answers, {
            name = packet.query,
            type = "A",
            ip = self.dns_records[packet.query]
        })
        -- Check cache
    elseif self.dns_cache[packet.query] then
        local cached = self.dns_cache[packet.query]
        if cached.expires > os.epoch("utc") then
            response.answers = cached.answers
        end
    else
        -- Forward to upstream DNS
        -- (simplified - would actually query upstream)
        table.insert(response.answers, {
            name = packet.query,
            type = "A",
            ip = "0.0.0.0" -- Placeholder
        })
    end

    self.interfaces[interface].modem.transmit(
            sender, os.getComputerID(), response
    )
end

function RouterDaemon:handleWirelessAuth(packet, sender, interface)
    if self.config.wireless.security == "OPEN" then
        -- No authentication needed
        self:acceptWirelessClient(sender, packet.client_mac)

    elseif self.config.wireless.security == "WPA3" then
        -- WPA3 SAE authentication (simplified)
        if packet.auth_type == "SAE_COMMIT" then
            -- Send SAE confirm
            local response = {
                type = "WIRELESS_AUTH",
                auth_type = "SAE_CONFIRM",
                challenge = tostring(math.random(1000000, 9999999))
            }

            self.interfaces[interface].modem.transmit(
                    sender, os.getComputerID(), response
            )

        elseif packet.auth_type == "SAE_CONFIRM" then
            -- Verify and accept client
            if self:verifyWPA3Auth(packet) then
                self:acceptWirelessClient(sender, packet.client_mac)
            end
        end
    end
end

function RouterDaemon:verifyWPA3Auth(packet)
    -- Simplified WPA3 verification
    -- In reality, this would verify the SAE handshake
    return packet.auth_data ~= nil
end

function RouterDaemon:acceptWirelessClient(sender, mac)
    self.wireless_clients[mac] = {
        computer_id = sender,
        connected_at = os.epoch("utc"),
        ip = nil -- Will be assigned via DHCP
    }

    -- Send association response
    local response = {
        type = "WIRELESS_AUTH",
        auth_type = "ASSOCIATED",
        success = true
    }

    if self.interfaces.wlan0 then
        self.interfaces.wlan0.modem.transmit(
                sender, os.getComputerID(), response
        )
    end
end

function RouterDaemon:handleWebAdmin(packet, sender, interface)
    -- Simple web admin interface
    -- Would normally serve HTML/API

    local response = {
        type = "HTTP",
        code = 200,
        body = "Router Admin Interface\n" ..
                "Status: Online\n" ..
                "Uptime: " .. (os.epoch("utc") - self.statistics.uptime_start) .. "ms\n" ..
                "Packets Forwarded: " .. self.statistics.packets_forwarded .. "\n" ..
                "Active DHCP Leases: " .. #self.dhcp_leases
    }

    self.interfaces[interface].modem.transmit(
            sender, os.getComputerID(), response
    )
end

function RouterDaemon:saveDHCPLeases()
    local file = fs.open("/var/lib/dhcp/leases", "w")
    if file then
        file.write(textutils.serialize(self.dhcp_leases))
        file.close()
    end
end

function RouterDaemon:loadDHCPLeases()
    if fs.exists("/var/lib/dhcp/leases") then
        local file = fs.open("/var/lib/dhcp/leases", "r")
        if file then
            local content = file.readAll()
            file.close()

            local leases = textutils.unserialize(content)
            if leases then
                self.dhcp_leases = leases
            end
        end
    end
end

function RouterDaemon:cleanupExpired()
    local now = os.epoch("utc")

    -- Cleanup DHCP leases
    for mac, lease in pairs(self.dhcp_leases) do
        if lease.expires < now then
            -- Mark IP as available again
            for _, ip_entry in ipairs(self.dhcp_pool) do
                if ip_entry.ip == lease.ip then
                    ip_entry.available = true
                    break
                end
            end

            self.dhcp_leases[mac] = nil
        end
    end

    -- Cleanup NAT table
    for conn_id, entry in pairs(self.nat_table) do
        if (now - entry.timestamp) > 300000 then -- 5 minutes
            self.nat_table[conn_id] = nil
        end
    end

    -- Cleanup DNS cache
    for domain, entry in pairs(self.dns_cache) do
        if entry.expires < now then
            self.dns_cache[domain] = nil
        end
    end
end

function RouterDaemon:run()
    self:init()

    -- Load saved state
    self:loadDHCPLeases()

    local cleanup_timer = os.startTimer(60) -- Cleanup every minute
    local stats_timer = os.startTimer(10) -- Update stats every 10 seconds

    print("[RouterD] Router daemon running...")

    while self.running do
        local event = {os.pullEvent()}

        if event[1] == "modem_message" then
            local side, frequency, replyFreq, message, distance =
            event[2], event[3], event[4], event[5], event[6]

            -- Determine interface
            local interface = nil
            for name, iface in pairs(self.interfaces) do
                if iface.side == side then
                    interface = name
                    break
                end
            end

            if interface and type(message) == "table" then
                self:handlePacket(interface, message, replyFreq)
            end

        elseif event[1] == "timer" then
            if event[2] == cleanup_timer then
                self:cleanupExpired()
                cleanup_timer = os.startTimer(60)

            elseif event[2] == stats_timer then
                -- Save statistics
                local file = fs.open("/var/run/router.stats", "w")
                if file then
                    file.write(textutils.serialize(self.statistics))
                    file.close()
                end
                stats_timer = os.startTimer(10)

            elseif event[2] == self.beacon_timer and self.config.wireless.enabled then
                -- Send wireless beacon
                if self.interfaces.wlan0 then
                    local beacon = {
                        type = "BEACON",
                        ssid = self.config.wireless.ssid,
                        security = self.config.wireless.security,
                        channel = self.config.wireless.channel
                    }

                    self.interfaces.wlan0.modem.transmit(
                            65534, os.getComputerID(), beacon
                    )
                end

                self.beacon_timer = os.startTimer(0.1)
            end

        elseif event[1] == "terminate" then
            print("[RouterD] Shutting down...")
            self.running = false
        end
    end

    -- Cleanup
    if fs.exists("/var/run/routerd.pid") then
        fs.delete("/var/run/routerd.pid")
    end

    print("[RouterD] Router daemon stopped")
end

-- Main execution
local function main()
    local config = loadConfig()
    local daemon = RouterDaemon:new(config)
    daemon:run()
end

-- Run the daemon
main()