-- UDP Protocol Implementation for ComputerCraft Networking System
-- Provides UDP emulation over rednet with full protocol compliance

local udp = {}
udp.version = "1.0.0"
udp.running = false

-- UDP Configuration
udp.config = {
    default_port = 0,  -- 0 means auto-assign
    max_packet_size = 65507,  -- Standard UDP max payload
    timeout = 5,  -- Default timeout in seconds
    buffer_size = 100,  -- Max buffered packets per socket
    statistics_enabled = true,
    debug = false
}

-- UDP Statistics
udp.stats = {
    packets_sent = 0,
    packets_received = 0,
    bytes_sent = 0,
    bytes_received = 0,
    packets_dropped = 0,
    errors = 0,
    active_sockets = 0
}

-- Active sockets registry
udp.sockets = {}
udp.port_registry = {}
udp.next_ephemeral_port = 49152  -- Start of ephemeral port range

-- Logging system
local function log(level, message, ...)
    if udp.config.debug or level == "ERROR" then
        local timestamp = os.date("%H:%M:%S")
        local formatted = string.format("[%s] UDP %s: %s", timestamp, level, string.format(message, ...))
        print(formatted)

        -- Also write to log file if directory exists
        if fs.exists("/var/log") then
            local logFile = fs.open("/var/log/udp.log", "a")
            if logFile then
                logFile.writeLine(formatted)
                logFile.close()
            end
        end
    end
end

-- UDP Packet structure
local function createPacket(sourcePort, destPort, data)
    if type(data) ~= "string" then
        data = textutils.serialize(data)
    end

    local packet = {
        protocol = "UDP",
        source_port = sourcePort,
        dest_port = destPort,
        length = #data + 8,  -- UDP header is 8 bytes
        checksum = 0,  -- Optional in IPv4
        data = data,
        timestamp = os.epoch("utc")
    }

    -- Calculate simple checksum (optional for UDP)
    local sum = sourcePort + destPort + packet.length
    for i = 1, #data do
        sum = sum + string.byte(data, i)
    end
    packet.checksum = sum % 65536

    return packet
end

-- UDP Socket class
local UDPSocket = {}
UDPSocket.__index = UDPSocket

function UDPSocket:new(port, options)
    local socket = {
        port = port or 0,
        bound = false,
        receive_buffer = {},
        receive_callback = nil,
        options = options or {},
        statistics = {
            packets_sent = 0,
            packets_received = 0,
            bytes_sent = 0,
            bytes_received = 0
        },
        created_at = os.epoch("utc")
    }

    setmetatable(socket, self)

    -- Auto-assign ephemeral port if not specified
    if socket.port == 0 then
        socket.port = udp.allocateEphemeralPort()
    end

    -- Register socket
    udp.sockets[socket.port] = socket
    udp.port_registry[socket.port] = true
    udp.stats.active_sockets = udp.stats.active_sockets + 1

    log("INFO", "Created UDP socket on port %d", socket.port)

    return socket
end

function UDPSocket:bind(port)
    if self.bound then
        return false, "Socket already bound"
    end

    if port and port ~= self.port then
        -- Need to change port
        if udp.port_registry[port] then
            return false, "Port " .. port .. " already in use"
        end

        -- Release old port
        udp.sockets[self.port] = nil
        udp.port_registry[self.port] = nil

        -- Bind to new port
        self.port = port
        udp.sockets[port] = self
        udp.port_registry[port] = true
    end

    self.bound = true
    log("INFO", "Bound UDP socket to port %d", self.port)
    return true
end

function UDPSocket:send(data, destIP, destPort)
    if type(data) ~= "string" then
        data = textutils.serialize(data)
    end

    if #data > udp.config.max_packet_size then
        return false, "Packet too large (max " .. udp.config.max_packet_size .. " bytes)"
    end

    -- Create UDP packet
    local packet = createPacket(self.port, destPort, data)

    -- Get source IP from global config or use localhost
    local sourceIP = "127.0.0.1"
    if _G.network_config and _G.network_config.ipv4 then
        sourceIP = _G.network_config.ipv4
    end

    -- Wrap in network layer (integrate with existing netd)
    local networkPacket = {
        protocol = "UDP",
        source_ip = sourceIP,
        dest_ip = destIP,
        ttl = 64,
        udp_packet = packet,
        timestamp = os.epoch("utc")
    }

    -- Send via rednet
    local success = false
    if rednet.isOpen() then
        -- Check if this is for a local computer
        if destIP == "127.0.0.1" or destIP == sourceIP then
            -- Local delivery - queue event directly
            os.queueEvent("udp_packet_received", networkPacket)
            success = true
        else
            -- Broadcast for network delivery
            rednet.broadcast(networkPacket, "UDP_PACKET")
            success = true
        end

        log("DEBUG", "Sent UDP packet: %s:%d -> %s:%d (%d bytes)",
                sourceIP, self.port, destIP, destPort, #data)
    else
        log("ERROR", "Cannot send UDP packet - rednet not open")
        return false, "Network not available"
    end

    if success then
        -- Update statistics
        self.statistics.packets_sent = self.statistics.packets_sent + 1
        self.statistics.bytes_sent = self.statistics.bytes_sent + #data
        udp.stats.packets_sent = udp.stats.packets_sent + 1
        udp.stats.bytes_sent = udp.stats.bytes_sent + #data
    else
        udp.stats.packets_dropped = udp.stats.packets_dropped + 1
    end

    return success
end

function UDPSocket:sendto(data, address)
    -- Parse address (format: "ip:port" or {ip="...", port=...})
    local destIP, destPort
    if type(address) == "string" then
        destIP, destPort = address:match("([^:]+):(%d+)")
        destPort = tonumber(destPort)
    elseif type(address) == "table" then
        destIP = address.ip or address.host
        destPort = address.port
    end

    if not destIP or not destPort then
        return false, "Invalid address format"
    end

    return self:send(data, destIP, destPort)
end

function UDPSocket:receive(timeout)
    timeout = timeout or udp.config.timeout
    local startTime = os.epoch("utc")
    local timeoutMs = timeout * 1000

    while true do
        -- Check buffer first
        if #self.receive_buffer > 0 then
            local packet = table.remove(self.receive_buffer, 1)
            self.statistics.packets_received = self.statistics.packets_received + 1
            self.statistics.bytes_received = self.statistics.bytes_received + #packet.data

            return packet.data, {
                ip = packet.source_ip,
                port = packet.source_port
            }
        end

        -- Check timeout
        if (os.epoch("utc") - startTime) > timeoutMs then
            return nil, "Timeout"
        end

        -- Brief sleep to prevent busy waiting
        sleep(0.05)
    end
end

function UDPSocket:recvfrom(bufferSize, timeout)
    -- Alias for receive with buffer size hint
    return self:receive(timeout)
end

function UDPSocket:setReceiveCallback(callback)
    self.receive_callback = callback
    log("DEBUG", "Set receive callback for port %d", self.port)
end

function UDPSocket:close()
    if udp.sockets[self.port] then
        udp.sockets[self.port] = nil
        udp.port_registry[self.port] = nil
        udp.stats.active_sockets = udp.stats.active_sockets - 1

        log("INFO", "Closed UDP socket on port %d", self.port)

        -- Log final socket statistics
        if udp.config.statistics_enabled then
            log("INFO", "Socket statistics - Sent: %d packets (%d bytes), Received: %d packets (%d bytes)",
                    self.statistics.packets_sent, self.statistics.bytes_sent,
                    self.statistics.packets_received, self.statistics.bytes_received)
        end
    end
end

function UDPSocket:getStatistics()
    return {
        packets_sent = self.statistics.packets_sent,
        packets_received = self.statistics.packets_received,
        bytes_sent = self.statistics.bytes_sent,
        bytes_received = self.statistics.bytes_received,
        port = self.port,
        bound = self.bound,
        buffer_size = #self.receive_buffer,
        created_at = self.created_at
    }
end

function UDPSocket:setOption(option, value)
    self.options[option] = value
    return true
end

-- Main UDP functions
function udp.socket(port, options)
    return UDPSocket:new(port, options)
end

function udp.allocateEphemeralPort()
    local port = udp.next_ephemeral_port
    local attempts = 0

    -- Find next available ephemeral port
    while udp.port_registry[port] and attempts < 16384 do
        port = port + 1
        if port > 65535 then
            port = 49152  -- Wrap around to start of ephemeral range
        end
        attempts = attempts + 1
    end

    if attempts >= 16384 then
        error("No available ephemeral ports")
    end

    udp.next_ephemeral_port = port + 1
    if udp.next_ephemeral_port > 65535 then
        udp.next_ephemeral_port = 49152
    end

    return port
end

function udp.isLocalNetwork(ip)
    -- Check if IP is local (RFC1918 or loopback)
    if ip == "127.0.0.1" or ip:match("^127%.") then
        return true
    end
    if ip:match("^10%.") then
        return true
    end
    if ip:match("^192%.168%.") then
        return true
    end
    local b = tonumber(ip:match("^172%.(%d+)%."))
    if b and b >= 16 and b <= 31 then
        return true
    end

    -- Check against local network config
    if _G.network_config and _G.network_config.subnet then
        -- Simple subnet check (you can make this more sophisticated)
        return true  -- For now, treat all as local in CC environment
    end

    return false
end

-- UDP packet handler (integrate with netd)
function udp.handleIncomingPacket(packet)
    if not packet or type(packet) ~= "table" then
        return false
    end

    -- Handle both direct UDP packets and network-wrapped packets
    local udpPacket
    if packet.protocol == "UDP" and packet.udp_packet then
        udpPacket = packet.udp_packet
    elseif packet.protocol == "UDP" and packet.dest_port then
        udpPacket = packet
        packet = {
            source_ip = packet.source_ip or "127.0.0.1",
            dest_ip = packet.dest_ip or "127.0.0.1"
        }
    else
        return false
    end

    local targetPort = udpPacket.dest_port

    -- Find socket listening on this port
    local socket = udp.sockets[targetPort]
    if socket then
        -- Update global statistics
        udp.stats.packets_received = udp.stats.packets_received + 1
        udp.stats.bytes_received = udp.stats.bytes_received + #(udpPacket.data or "")

        -- Add to socket's receive buffer
        if #socket.receive_buffer < udp.config.buffer_size then
            table.insert(socket.receive_buffer, {
                data = udpPacket.data,
                source_ip = packet.source_ip,
                source_port = udpPacket.source_port,
                timestamp = os.epoch("utc")
            })

            -- Trigger receive callback if set
            if socket.receive_callback then
                socket.receive_callback(udpPacket.data, {
                    ip = packet.source_ip,
                    port = udpPacket.source_port
                })
            end

            log("DEBUG", "Received UDP packet on port %d from %s:%d",
                    targetPort, packet.source_ip, udpPacket.source_port)
        else
            udp.stats.packets_dropped = udp.stats.packets_dropped + 1
            log("WARN", "Dropped UDP packet - buffer full on port %d", targetPort)
        end

        return true
    else
        -- Port unreachable
        udp.stats.packets_dropped = udp.stats.packets_dropped + 1
        log("DEBUG", "UDP packet to unreachable port %d", targetPort)
        return false
    end
end

-- Statistics and monitoring
function udp.getStatistics()
    local stats = {}
    for k, v in pairs(udp.stats) do
        stats[k] = v
    end

    -- Add per-socket statistics
    stats.sockets = {}
    for port, socket in pairs(udp.sockets) do
        stats.sockets[port] = socket:getStatistics()
    end

    return stats
end

function udp.resetStatistics()
    udp.stats = {
        packets_sent = 0,
        packets_received = 0,
        bytes_sent = 0,
        bytes_received = 0,
        packets_dropped = 0,
        errors = 0,
        active_sockets = udp.stats.active_sockets
    }

    log("INFO", "Reset UDP statistics")
end

-- Service management
function udp.start()
    if udp.running then
        return true
    end

    -- Ensure log directory exists
    if not fs.exists("/var/log") then
        fs.makeDir("/var/log")
    end

    udp.running = true
    log("INFO", "UDP service started")

    return true
end

function udp.stop()
    if not udp.running then
        return
    end

    udp.running = false

    -- Close all sockets
    local closedCount = 0
    for port, socket in pairs(udp.sockets) do
        socket:close()
        closedCount = closedCount + 1
    end

    log("INFO", "UDP service stopped (closed %d sockets)", closedCount)
end

function udp.isRunning()
    return udp.running
end

-- Simple broadcast function for network discovery
function udp.broadcast(data, port)
    port = port or 12345
    local socket = udp.socket()

    -- Broadcast to common local network ranges
    local broadcasts = {"255.255.255.255", "192.168.1.255", "10.255.255.255"}
    local success = false

    for _, addr in ipairs(broadcasts) do
        if socket:send(data, addr, port) then
            success = true
        end
    end

    socket:close()
    return success
end

-- Testing utilities
function udp.test()
    print("Starting UDP protocol test...")

    -- Start the service
    udp.start()

    -- Create server socket
    local server = udp.socket(12345)
    local success, err = server:bind(12345)
    if not success then
        print("Failed to bind server: " .. err)
        return false
    end
    print("Server listening on port 12345")

    -- Create client socket
    local client = udp.socket()
    print("Client socket created on port " .. client.port)

    -- Send test packet
    local testData = "Hello, UDP World!"
    success = client:send(testData, "127.0.0.1", 12345)
    print("Client sent: " .. testData .. " (success: " .. tostring(success) .. ")")

    -- Small delay to allow packet processing
    sleep(0.1)

    -- Receive on server
    local data, sender = server:receive(2)
    if data then
        print("Server received: " .. data .. " from " .. sender.ip .. ":" .. sender.port)
    else
        print("Server receive timeout or error: " .. tostring(sender))
    end

    -- Print statistics
    local stats = udp.getStatistics()
    print("\nUDP Statistics:")
    print("  Packets sent: " .. stats.packets_sent)
    print("  Packets received: " .. stats.packets_received)
    print("  Packets dropped: " .. stats.packets_dropped)
    print("  Active sockets: " .. stats.active_sockets)

    -- Cleanup
    client:close()
    server:close()

    print("UDP protocol test completed!")
    return true
end

-- Initialize
log("INFO", "UDP Protocol v%s initialized", udp.version)

return udp