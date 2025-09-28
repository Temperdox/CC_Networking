-- /util/connection_manager.lua
-- Connection manager with UDP support
local Logger = require("util.logger")

local ConnectionManager = {}
ConnectionManager.__index = ConnectionManager

-- Create logger for ConnectionManager
local logger = Logger and Logger:new({
    title = "Connection Manager",
    logFile = "logs/connection_manager.log",
    maxLogs = 1000
}) or nil

local protocols = {}

function ConnectionManager.connectionDebugString(self)
    return string.format("[Connection %s] Protocol: %s, Address: %s, Status: %s",
            self.id, self.protocol, self.address, self.status or "unknown")
end

function ConnectionManager:DebugPrint(msg)
    if self.debug then
        print(string.format("[ConnectionManager] %s", msg))
    end
    if self.logger then
        self.logger:debug(msg)
    end
end

local PROTOCOL_NAMES = {
    websocket = "WebSocket",
    http = "HTTP",
    https = "HTTPS",
    webrtc = "WebRTC",
    tcp = "TCP",
    udp = "UDP",  -- Add UDP
    mqtt = "MQTT",
    ftp = "FTP",
    ssh = "SSH"
}

local STATUSES = {
    -- Common statuses for network connections
    initialized = "initialized",
    connecting = "connecting",
    connected = "connected",
    disconnected = "disconnected",
    reconnecting = "reconnecting",
    error = "error",
    closed = "closed",
    -- Protocol-specific statuses
    websocket_open = "websocket_open",
    websocket_closing = "websocket_closing",
    websocket_closed = "websocket_closed",
    http_request_sent = "http_request_sent",
    http_response_received = "http_response_received",
    webrtc_offer = "webrtc_offer",
    webrtc_answer = "webrtc_answer",
    webrtc_ice = "webrtc_ice",
    tcp_listening = "tcp_listening",
    tcp_established = "tcp_established",
    udp_bound = "udp_bound",  -- Add UDP statuses
    udp_sending = "udp_sending",
    udp_receiving = "udp_receiving",
    mqtt_subscribed = "mqtt_subscribed",
    mqtt_published = "mqtt_published",
    ftp_logged_in = "ftp_logged_in",
    ftp_transferring = "ftp_transferring",
    ssh_authenticated = "ssh_authenticated",
    ssh_channel_open = "ssh_channel_open"
}

function ConnectionManager:new(options)
    local obj = {}
    setmetatable(obj, self)

    obj.connections = {}
    obj.protocols = {}
    obj.eventHandlers = {}
    obj.connectionCount = 0
    obj.defaultPorts = {
        websocket = 80,
        http = 80,
        https = 443,
        webrtc = 9000,
        tcp = 8080,
        udp = 0,  -- 0 means auto-assign for UDP
        mqtt = 1883,
        ftp = 21,
        ssh = 22
    }

    obj.debug = options and options.debug or true

    -- Use provided logger or create new one
    obj.logger = options and options.logger or logger

    if obj.logger then
        obj.logger:info("ConnectionManager initialized")
        obj.logger:debug("Default ports configured for %d protocols", 9)
    end

    obj:loadProtocols()
    obj:startConnectionMonitor()

    return obj
end

function ConnectionManager:setDebug(enabled)
    self.debug = enabled
    if self.logger then
        self.logger:debug("Debug mode %s", enabled and "enabled" or "disabled")
    end
end

function ConnectionManager:loadProtocols()
    -- Load protocol modules
    local protocolFiles = {
        websocket = "protocols.websocket",
        http = "protocols.http_client",
        https = "protocols.http_client",
        webrtc = "protocols.webrtc",
        tcp = "protocols.tcp",
        udp = "protocols.udp",  -- Add UDP protocol
        mqtt = "protocols.mqtt",
        ftp = "protocols.ftp",
        ssh = "protocols.ssh"
    }

    for name, path in pairs(protocolFiles) do
        local success, protocol = pcall(require, path)
        if success then
            self.protocols[name] = protocol
            if self.logger then
                self.logger:debug("Loaded protocol: %s", name)
            end
        else
            -- Try alternative loading method
            local altPath = "/" .. path:gsub("%.", "/") .. ".lua"
            if fs.exists(altPath) then
                success, protocol = pcall(dofile, altPath)
                if success then
                    self.protocols[name] = protocol
                    if self.logger then
                        self.logger:debug("Loaded protocol from file: %s", name)
                    end
                else
                    if self.logger then
                        self.logger:warn("Failed to load protocol %s: %s", name, protocol)
                    end
                end
            else
                if self.logger then
                    self.logger:warn("Protocol file not found: %s", name)
                end
            end
        end
    end
end

function ConnectionManager:createConnection(protocolName, address, options)
    protocolName = string.lower(protocolName)
    local protocol = self.protocols[protocolName]

    if not protocol then
        local err = "Protocol not loaded: " .. protocolName
        if self.logger then self.logger:error(err) end
        error(err)
    end

    -- Parse address based on protocol
    local host, port, path = self:parseAddress(address, protocolName)

    -- Create connection based on protocol
    local conn
    if protocolName == "websocket" then
        conn = protocol:new(address, options)
    elseif protocolName == "http" or protocolName == "https" then
        conn = protocol:new(host, options)
        conn.port = port
        conn.path = path
    elseif protocolName == "webrtc" then
        -- WebRTC uses peer ID instead of host:port
        conn = protocol:new(address, options)
    elseif protocolName == "tcp" then
        conn = protocol:new(host, port, options)
    elseif protocolName == "udp" then
        -- UDP socket creation
        conn = protocol.socket(port, options)
        if host then
            -- Store destination for later sends
            conn.defaultDest = {ip = host, port = port}
        end
    elseif protocolName == "mqtt" then
        conn = protocol:new(host, port, options)
    elseif protocolName == "ftp" then
        conn = protocol:new(host, options)
        conn.port = port
    elseif protocolName == "ssh" then
        conn = protocol:new(host, port, options)
    end

    if not conn then
        local err = "Failed to create connection"
        if self.logger then self.logger:error(err) end
        error(err)
    end

    self.connectionCount = self.connectionCount + 1
    local connId = string.format("%s-%d-%d", protocolName, self.connectionCount, os.time())

    self.connections[connId] = {
        id = connId,
        connection = conn,
        protocol = protocolName,
        address = address,
        host = host,
        port = port,
        path = path,
        status = STATUSES.initialized,
        createdAt = os.time(),
        stats = {
            bytesSent = 0,
            bytesReceived = 0,
            messagesSent = 0,
            messagesReceived = 0,
            errors = 0,
            -- UDP specific stats
            packetsDropped = 0,
            outOfOrder = 0
        },
        debugString = ConnectionManager.connectionDebugString
    }

    if self.debug then
        print(ConnectionManager.connectionDebugString(self.connections[connId]))
    end

    if self.logger then
        self.logger:info("Created connection %s for protocol %s", connId, protocolName)
    end

    return self.connections[connId]
end

function ConnectionManager:parseAddress(address, protocolName)
    local host, port, path

    -- Special handling for UDP addresses
    if protocolName == "udp" then
        if type(address) == "table" then
            host = address.host or address.ip
            port = address.port
        elseif type(address) == "string" then
            host, port = address:match("^([^:]+):(%d+)$")
            if not host then
                -- Maybe just a port number
                port = tonumber(address)
            end
        elseif type(address) == "number" then
            port = address
        end
        port = tonumber(port) or 0
        return host, port, nil
    end

    -- Standard URL parsing for other protocols
    local url_pattern = "^(%w+)://([^:/]+):?(%d*)(/?.*)$"
    local host_port_pattern = "^([^:/]+):?(%d*)(/?.*)$"

    local protocol_match, h, p, pa = address:match(url_pattern)
    if protocol_match then
        host, port, path = h, p, pa
    else
        host, port, path = address:match(host_port_pattern)
    end

    -- Default ports if not specified
    port = tonumber(port) or self.defaultPorts[protocolName] or 80
    path = path ~= "" and path or "/"

    return host, port, path
end

function ConnectionManager:connect(connId, ...)
    local conn = self.connections[connId]
    if not conn then
        error("Connection not found: " .. connId)
    end

    self:DebugPrint(string.format("Connecting %s...", connId))
    conn.status = STATUSES.connecting

    local success, result, message

    if conn.protocol == "udp" then
        -- UDP "connection" is just binding
        if conn.port and conn.port > 0 then
            success, message = conn.connection:bind(conn.port)
        else
            success = true  -- Auto-assigned port
            message = "Socket created with auto-assigned port"
        end

        if success then
            conn.status = STATUSES.udp_bound
            result = STATUSES.connected
        else
            conn.status = STATUSES.error
            result = STATUSES.error
        end
    else
        -- Other protocols
        success, result, message = pcall(conn.connection.connect, conn.connection, ...)

        if success then
            conn.status = result == STATUSES.connected and STATUSES.connected or result
        else
            conn.status = STATUSES.error
            result = STATUSES.error
            message = result
        end
    end

    if self.logger then
        if success and result == STATUSES.connected then
            self.logger:info("Connection %s established", connId)
        else
            self.logger:warn("Connection %s failed: %s", connId, message or "Unknown error")
        end
    end

    self:DebugPrint(string.format("Connection %s status: %s", connId, conn.status))
    return success, result, message
end

function ConnectionManager:send(connId, data, ...)
    local conn = self.connections[connId]
    if not conn then
        error("Connection not found: " .. connId)
    end

    local success, result

    if conn.protocol == "udp" then
        -- UDP send with optional destination override
        local destIP, destPort = ...
        if not destIP and conn.connection.defaultDest then
            destIP = conn.connection.defaultDest.ip
            destPort = conn.connection.defaultDest.port
        end

        if destIP and destPort then
            conn.status = STATUSES.udp_sending
            success, result = pcall(conn.connection.send, conn.connection, data, destIP, destPort)
        else
            success = false
            result = "No destination specified for UDP send"
        end
    else
        -- Other protocols
        success, result = pcall(conn.connection.send, conn.connection, data, ...)
    end

    if success then
        conn.stats.messagesSent = conn.stats.messagesSent + 1
        conn.stats.bytesSent = conn.stats.bytesSent + #tostring(data)
        if self.logger then
            self.logger:trace("Sent data on connection %s (%d bytes)", connId, #tostring(data))
        end
    else
        conn.stats.errors = conn.stats.errors + 1
        if self.logger then
            self.logger:error("Failed to send on connection %s: %s", connId, result)
        end
    end

    return success, result
end

function ConnectionManager:receive(connId, timeout)
    local conn = self.connections[connId]
    if not conn then
        error("Connection not found: " .. connId)
    end

    local success, data, source

    if conn.protocol == "udp" then
        -- UDP receive with timeout
        conn.status = STATUSES.udp_receiving
        success, data, source = pcall(conn.connection.receive, conn.connection, timeout)

        if success and data then
            -- source contains {ip, port} for UDP
            conn.stats.messagesReceived = conn.stats.messagesReceived + 1
            conn.stats.bytesReceived = conn.stats.bytesReceived + #tostring(data)
            if self.logger then
                self.logger:trace("Received UDP data on connection %s from %s:%d (%d bytes)",
                        connId, source.ip, source.port, #tostring(data))
            end
            return true, data, source
        end
    else
        -- Other protocols
        success, data = pcall(conn.connection.receive, conn.connection, timeout)

        if success and data then
            conn.stats.messagesReceived = conn.stats.messagesReceived + 1
            conn.stats.bytesReceived = conn.stats.bytesReceived + #tostring(data)
            if self.logger then
                self.logger:trace("Received data on connection %s (%d bytes)", connId, #tostring(data))
            end
            return true, data
        end
    end

    if not success then
        conn.stats.errors = conn.stats.errors + 1
        if self.logger then
            self.logger:error("Failed to receive on connection %s: %s", connId, data or "Unknown error")
        end
    end

    return false, data
end

function ConnectionManager:disconnect(connId)
    local conn = self.connections[connId]
    if not conn then
        return false, "Connection not found"
    end

    self:DebugPrint(string.format("Disconnecting %s...", connId))

    local success, result
    if conn.connection.close then
        success, result = pcall(conn.connection.close, conn.connection)
    elseif conn.connection.disconnect then
        success, result = pcall(conn.connection.disconnect, conn.connection)
    else
        success = true
    end

    if success then
        conn.status = STATUSES.disconnected
        if self.logger then
            self.logger:info("Connection %s disconnected", connId)
        end
    else
        if self.logger then
            self.logger:warn("Failed to disconnect %s: %s", connId, result or "Unknown error")
        end
    end

    -- Remove from active connections
    self.connections[connId] = nil

    return success, result
end

function ConnectionManager:getConnectionStatus(connId)
    local conn = self.connections[connId]
    if not conn then
        return nil, "Connection not found"
    end

    return conn.status, conn.stats
end

function ConnectionManager:listConnections()
    local list = {}
    for id, conn in pairs(self.connections) do
        table.insert(list, {
            id = id,
            protocol = conn.protocol,
            address = conn.address,
            status = conn.status,
            created = conn.createdAt,
            stats = conn.stats
        })
    end
    return list
end

function ConnectionManager:addEventListener(event, handler)
    if not self.eventHandlers[event] then
        self.eventHandlers[event] = {}
    end
    table.insert(self.eventHandlers[event], handler)
end

function ConnectionManager:removeEventListener(event, handler)
    if self.eventHandlers[event] then
        for i, h in ipairs(self.eventHandlers[event]) do
            if h == handler then
                table.remove(self.eventHandlers[event], i)
                break
            end
        end
    end
end

function ConnectionManager:triggerEvent(event, ...)
    if self.eventHandlers[event] then
        for _, handler in ipairs(self.eventHandlers[event]) do
            local success, err = pcall(handler, ...)
            if not success and self.logger then
                self.logger:error("Event handler error for %s: %s", event, err)
            end
        end
    end
end

function ConnectionManager:startConnectionMonitor()
    -- Start a background task to monitor connection health
    if not self.monitorRunning then
        self.monitorRunning = true

        -- This would typically run in a parallel thread
        -- For now, we'll just set up the structure
        self.monitorTask = function()
            while self.monitorRunning do
                for id, conn in pairs(self.connections) do
                    -- Check connection health based on protocol
                    if conn.protocol == "tcp" and conn.connection.isConnected then
                        if not conn.connection:isConnected() then
                            conn.status = STATUSES.disconnected
                            self:triggerEvent("disconnected", id)
                        end
                    elseif conn.protocol == "websocket" and conn.connection.isOpen then
                        if not conn.connection:isOpen() then
                            conn.status = STATUSES.websocket_closed
                            self:triggerEvent("disconnected", id)
                        end
                    end
                    -- UDP doesn't have a connection state to monitor
                end
                sleep(5) -- Check every 5 seconds
            end
        end

        if self.logger then
            self.logger:debug("Connection monitor started")
        end
    end
end

function ConnectionManager:stopConnectionMonitor()
    self.monitorRunning = false
    if self.logger then
        self.logger:debug("Connection monitor stopped")
    end
end

function ConnectionManager:cleanup()
    -- Disconnect all connections
    for id, _ in pairs(self.connections) do
        self:disconnect(id)
    end

    -- Stop monitor
    self:stopConnectionMonitor()

    if self.logger then
        self.logger:info("ConnectionManager cleaned up")
    end
end

-- UDP-specific helper functions
function ConnectionManager:createUDPSocket(port, options)
    return self:createConnection("udp", port or 0, options)
end

function ConnectionManager:sendUDPDatagram(destIP, destPort, data, sourcePort)
    -- Create temporary socket for one-off sends
    local connId = self:createUDPSocket(sourcePort)
    local success, result = self:send(connId, data, destIP, destPort)
    self:disconnect(connId)
    return success, result
end

function ConnectionManager:listenUDP(port, callback, options)
    local connId = self:createUDPSocket(port, options)
    local conn = self.connections[connId]

    if not conn then
        return nil, "Failed to create UDP socket"
    end

    -- Bind to port
    local success, result = self:connect(connId)
    if not success then
        return nil, result
    end

    -- Set up receive callback if provided
    if callback and conn.connection.setReceiveCallback then
        conn.connection:setReceiveCallback(callback)
    end

    return connId
end

return ConnectionManager