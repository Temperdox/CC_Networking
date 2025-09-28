-- connection_manager.lua
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
        mqtt = 1883,
        ftp = 21,
        ssh = 22
    }

    obj.debug = options and options.debug or true

    -- Use provided logger or create new one
    obj.logger = options and options.logger or logger

    if obj.logger then
        obj.logger:info("ConnectionManager initialized")
        obj.logger:debug("Default ports configured for %d protocols", 8)
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
        mqtt = "protocols.mqtt",
        ftp = "protocols.ftp",
        ssh = "protocols.ssh"
    }

    for name, path in pairs(protocolFiles) do
        local success, protocol = pcall(require, path)
        if success then
            self.protocols[name] = protocol
            print(string.format("[Manager] Loaded protocol: %s", protocol.PROTOCOL_NAME or name))
            if self.logger then
                self.logger:info("Loaded protocol: %s from %s", name, path)
            end
        else
            print(string.format("[Manager] Failed to load %s: %s", name, protocol))
            if self.logger then
                self.logger:error("Failed to load protocol %s from %s: %s", name, path, tostring(protocol))
            end
        end
    end
end

function ConnectionManager:createConnection(protocolName, address, options)
    if self.logger then
        self.logger:info("Creating %s connection to %s", protocolName, address)
    end

    local protocol = self.protocols[protocolName]
    options = options or {}
    local conn = nil

    if not protocol then
        local err = string.format("Protocol '%s' not supported", protocolName)
        if self.logger then self.logger:error(err) end
        error(err)
    end

    local host, port, path = self:parseAddress(address, protocolName)

    port = port or self.defaultPorts[protocolName]
    if not port then
        local err = string.format("No default port for protocol '%s'", protocolName)
        if self.logger then self.logger:error(err) end
        error(err)
    end

    if self.logger then
        self.logger:debug("Parsed address - Host: %s, Port: %d, Path: %s", host, port, path or "/")
    end

    -- Pass logger to protocol instances
    options.logger = options.logger or self.logger

    if protocolName == "websocket" then
        conn = protocol:new(address, options)
    elseif protocolName == "http" or protocolName == "https" then
        conn = protocol:new(address, options)
    elseif protocolName == "webrtc" then
        -- WebRTC uses peer ID instead of host:port
        conn = protocol:new(address, options)
    elseif protocolName == "tcp" then
        conn = protocol:new(host, port, options)
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
            errors = 0
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
    local url_pattern = "^(%w+)://([^:/]+):?(%d*)(/?.*)$"
    local host_port_pattern = "^([^:/]+):?(%d*)$"
    local pro, h, p, pa = address:match(url_pattern)

    if h then
        host = h
        port = tonumber(p) or self.defaultPorts[protocolName]
        path = pa ~= "" and pa or "/"
    else
        local h2, p2 = address:match(host_port_pattern)
        if h2 then
            host = h2
            port = tonumber(p2) or self.defaultPorts[protocolName]
        else
            host = address
            port = self.defaultPorts[protocolName]
        end
        path = "/"
    end

    return host, port, path
end

function ConnectionManager:connect(connId, credentials)
    local connectionData = self.connections[connId]
    if not connectionData then
        local err = "Connection ID not found"
        if self.logger then self.logger:error("Connect failed: %s", err) end
        return false, error(err)
    end

    local conn = connectionData.connection
    local protocol = connectionData.protocol

    connectionData.status = STATUSES.connecting
    self:DebugPrint(string.format("Connecting to %s (%s)", connectionData.address, protocol))

    if protocol == "tcp" or protocol == "websocket" then
        if conn.connect then
            local success, err = conn:connect()
            if success then
                connectionData.status = STATUSES.connected
                self:DebugPrint(string.format("Connected to %s", connectionData.address))
                return success
            else
                connectionData.status = STATUSES.error
                connectionData.stats.errors = connectionData.stats.errors + 1
                self:DebugPrint(string.format("Connection error to %s: %s", connectionData.address, err))
                return false, err
            end
        end
    elseif protocol == "mqtt" then
        if credentials and credentials.username and credentials.password then
            local success, err = conn:connect(credentials.username, credentials.password)
            if success then
                connectionData.status = STATUSES.connected
                self:DebugPrint(string.format("Connected to %s", connectionData.address))
                return success
            else
                connectionData.status = STATUSES.error
                connectionData.stats.errors = connectionData.stats.errors + 1
                self:DebugPrint(string.format("Connection error to %s: %s", connectionData.address, err))
                return false, err
            end
        else
            local success, err = conn:connect()
            if success then
                connectionData.status = STATUSES.connected
                self:DebugPrint(string.format("Connected to %s", connectionData.address))
                return success
            else
                connectionData.status = STATUSES.error
                connectionData.stats.errors = connectionData.stats.errors + 1
                self:DebugPrint(string.format("Connection error to %s: %s", connectionData.address, err))
                return false, err
            end
        end
    elseif protocol == "ftp" then
        local success, err = conn:connect()
        if success and credentials and credentials.username and credentials.password then
            local loginSuccess, loginErr = conn:login(credentials.username, credentials.password)
            if loginSuccess then
                connectionData.status = STATUSES.connected
                self:DebugPrint(string.format("Connected and logged in to %s", connectionData.address))
                return true
            else
                connectionData.status = STATUSES.error
                connectionData.stats.errors = connectionData.stats.errors + 1
                self:DebugPrint(string.format("Login error to %s: %s", connectionData.address, loginErr))
                return false, loginErr
            end
        end
    elseif protocol == "ssh" then
        local success, err = conn:connect()
        if success and credentials then
            local authSuccess, authErr
            if credentials.password then
                authSuccess, authErr = conn:passwordAuth(credentials.username, credentials.password)
            elseif credentials.privateKey then
                authSuccess, authErr = conn:publicKeyAuth(credentials.username, credentials.privateKey)
            end

            if authSuccess then
                connectionData.status = STATUSES.connected
                self:DebugPrint(string.format("Connected and authenticated to %s", connectionData.address))
                return true
            else
                connectionData.status = STATUSES.error
                connectionData.stats.errors = connectionData.stats.errors + 1
                self:DebugPrint(string.format("Authentication error to %s: %s", connectionData.address, authErr))
                return false, authErr
            end
        else
            connectionData.status = STATUSES.error
            connectionData.stats.errors = connectionData.stats.errors + 1
            self:DebugPrint(string.format("Missing credentials for SSH connection to %s", connectionData.address))
            return false, "Missing credentials"
        end
    elseif protocol == "webrtc" then
        if credentials and credentials.peerId then
            local success, err = conn:connectToPeer(credentials.peerId, credentials.offer)
            if success then
                connectionData.status = STATUSES.connected
                self:DebugPrint(string.format("Connected to %s", connectionData.address))
                return success
            else
                connectionData.status = STATUSES.error
                connectionData.stats.errors = connectionData.stats.errors + 1
                self:DebugPrint(string.format("Connection error to %s: %s", connectionData.address, err))
                return false, err
            end
        else
            connectionData.status = STATUSES.error
            connectionData.stats.errors = connectionData.stats.errors + 1
            self:DebugPrint(string.format("Missing peer ID for WebRTC connection to %s", connectionData.address))
            return false, "Missing peer ID"
        end
    elseif protocol == "http" or protocol == "https" then
        -- HTTP connections are stateless; no persistent connection needed
        connectionData.status = STATUSES.connected
        self:DebugPrint(string.format("HTTP connection ready for %s", connectionData.address))
        return true
    else
        connectionData.status = STATUSES.error
        connectionData.stats.errors = connectionData.stats.errors + 1
        self:DebugPrint(string.format("Unsupported protocol '%s' for connection to %s", protocol, connectionData.address))
        return false, "Unsupported protocol"
    end
end

function ConnectionManager:send(connId, data, options)
    local connectionData = self.connections[connId]
    if not connectionData then
        local err = "Connection ID not found"
        if self.logger then self.logger:error("Send failed: %s", err) end
        return false, error(err)
    end

    local conn = connectionData.connection
    local protocol = connectionData.protocol

    connectionData.stats.messagesSent = connectionData.stats.messagesSent + 1
    connectionData.stats.bytesSent = connectionData.stats.bytesSent + #tostring(data)

    if self.logger then
        self.logger:debug("Sending data via %s connection %s (%d bytes)", protocol, connId, #tostring(data))
    end

    if protocol == "http" or protocol == "https" then
        if options and options.endpoint then
            return conn:post(options.endpoint, data, options.headers)
        else
            return conn:post("/", data, options.headers)
        end
    elseif protocol == "mqtt" then
        if options and options.topic then
            return conn:publish(options.topic, data, options.qos or 0, options.retain or false)
        else
            return conn:publish("default", data, options.qos or 0, options.retain or false)
        end
    elseif protocol == "webrtc" then
        if options and options.peerId then
            return conn:sendDataToPeer(options.peerId, options.channel or "default", data)
        else
            return conn:sendDataToAllPeers(options.channel or "default", data)
        end
    elseif protocol == "ftp" then
        if options and options.remotePath then
            return conn:upload(options.localFile or data, options.remotePath)
        else
            return false, error("Missing remotePath for FTP upload")
        end
    elseif protocol == "ssh" then
        if options and options.channel then
            return conn:sendToChannel(options.channel, data)
        else
            return conn:executeCommand(data)
        end
    else
        return self:sendRaw(connId, data, options)
    end
end

function ConnectionManager:receive(id, timeout)
    local connectionData = self.connections[id]
    if not connectionData then
        local err = "Connection ID not found"
        if self.logger then self.logger:error("Receive failed: %s", err) end
        return false, error(err)
    end

    local conn = connectionData.connection

    if self.logger then
        self.logger:debug("Receiving data from connection %s (timeout: %s)", id, tostring(timeout))
    end

    local timer = nil
    if timeout and timeout > 0 then
        timer = os.startTimer(timeout)
    end

    while true do
        local event, param1, param2, param3 = os.pullEvent()
        if event == "network_message" and param1 == id then
            connectionData.stats.messagesReceived = connectionData.stats.messagesReceived + 1
            connectionData.stats.bytesReceived = connectionData.stats.bytesReceived + #tostring(param2)

            if self.logger then
                self.logger:debug("Received message on connection %s (%d bytes)", id, #tostring(param2))
            end

            if timer then
                os.cancelTimer(timer)
            end
            return true, param2, param3
        elseif event == "timer" and timer and param1 == timer then
            break
        end
    end

    if self.logger then
        self.logger:debug("Receive timeout on connection %s", id)
    end

    return false, "Timeout"
end

function ConnectionManager:getConnection(connId)
    local connectionData = self.connections[connId]
    return connectionData and connectionData.connection or nil
end

function ConnectionManager:getConnectionInfo(connId)
    return self.connections[connId] or nil
end

function ConnectionManager:listConnections(protocol)
    local list = {}
    for id, data in pairs(self.connections) do
        if not protocol or data.protocol == protocol then
            table.insert(list, {
                id = id,
                protocol = data.protocol,
                address = data.address,
                status = data.status,
                createdAt = data.createdAt,
                stats = data.stats
            })
        end
    end

    if self.logger then
        self.logger:debug("Listed %d connections %s", #list, protocol and ("for protocol " .. protocol) or "total")
    end

    return list
end

function ConnectionManager:closeConnection(connId)
    local connectionData = self.connections[connId]
    if not connectionData then
        local err = "Connection ID not found"
        if self.logger then self.logger:error("Close failed: %s", err) end
        return false, error(err)
    end

    local conn = connectionData.connection
    local protocol = connectionData.protocol

    if self.logger then
        self.logger:info("Closing connection %s (%s)", connId, protocol)
    end

    if conn.close then
        local success, err = conn:close()
        if success then
            connectionData.status = STATUSES.closed
            self:DebugPrint(string.format("Closed connection to %s", connectionData.address))
            self.connections[connId] = nil
            return true
        else
            connectionData.status = STATUSES.error
            connectionData.stats.errors = connectionData.stats.errors + 1
            self:DebugPrint(string.format("Error closing connection to %s: %s", connectionData.address, err))
            return false, err
        end
    else
        self.connections[connId] = nil
        self:DebugPrint(string.format("Removed connection to %s (no close method)", connectionData.address))
        return true
    end
end

function ConnectionManager:closeAllByProtocol(protocol)
    local closedCount = 0

    if self.logger then
        self.logger:info("Closing all %s connections", protocol)
    end

    for connId, data in pairs(self.connections) do
        if data.protocol == protocol then
            local success, err = self:closeConnection(connId)
            if success then
                closedCount = closedCount + 1
                self:DebugPrint(string.format("Closed connection %s", connId))
            else
                self:DebugPrint(string.format("Failed to close connection %s: %s", connId, err))
            end
        end
    end

    if self.logger then
        self.logger:info("Closed %d %s connections", closedCount, protocol)
    end

    return closedCount
end

function ConnectionManager:closeAllConnections()
    if self.logger then
        self.logger:info("Closing all connections")
    end

    local totalCount = 0
    for connId, _ in pairs(self.connections) do
        local success, err = self:closeConnection(connId)
        if success then
            totalCount = totalCount + 1
            self:DebugPrint(string.format("Closed connection %s", connId))
        else
            self:DebugPrint(string.format("Failed to close connection %s: %s", connId, err))
        end
    end

    if self.logger then
        self.logger:info("Closed %d total connections", totalCount)
    end

    return totalCount
end

function ConnectionManager:sendRaw(connId, data, options)
    local connectionData = self.connections[connId]
    if not connectionData then
        local err = "Connection ID not found"
        if self.logger then self.logger:error("SendRaw failed: %s", err) end
        return false, error(err)
    end

    local conn = connectionData.connection
    local protocol = connectionData.protocol

    if conn.send then
        local success, err = conn:send(data)
        if success then
            connectionData.stats.messagesSent = connectionData.stats.messagesSent + 1
            connectionData.stats.bytesSent = connectionData.stats.bytesSent + #tostring(data)

            if self.logger then
                self.logger:trace("Raw send successful on connection %s", connId)
            end

            return true
        else
            connectionData.status = STATUSES.error
            connectionData.stats.errors = connectionData.stats.errors + 1
            self:DebugPrint(string.format("Send error to %s: %s", connectionData.address, err))
            return false, err
        end
    else
        return false, error("Send method not supported for this protocol")
    end
end

function ConnectionManager:setEventHandler(connId, event, handler)
    local connectionData = self.connections[connId]
    if not connectionData then
        local err = "Connection ID not found"
        if self.logger then self.logger:error("SetEventHandler failed: %s", err) end
        return false, error(err)
    end

    local conn = connectionData.connection

    if self.logger then
        self.logger:debug("Setting event handler for %s on connection %s", event, connId)
    end

    if conn.on then
        conn:on(event, handler)
    else
        return false, error("Event handling not supported for this protocol")
    end

    if not self.eventHandlers[connId] then
        self.eventHandlers[connId] = {}
    end
    self.eventHandlers[connId][event] = handler
    return true
end

function ConnectionManager:startConnectionMonitor()
    if self.logger then
        self.logger:info("Starting connection monitor")
    end

    parallel.waitForAny(function()
        while true do
            for connId, data in pairs(self.connections) do
                local conn = data.connection
                if conn.checkStatus then
                    local status = conn:checkStatus()
                    if status and status ~= data.status then
                        local oldStatus = data.status
                        data.status = status

                        self:DebugPrint(string.format("Connection %s status changed from %s to %s",
                                connId, oldStatus, status))

                        -- Protocol-specific health checks or actions
                        if self.eventHandlers[connId] and self.eventHandlers[connId]["status"] then
                            pcall(self.eventHandlers[connId]["status"], connId, status)
                        end
                        if conn.onStatusChange then
                            pcall(function() conn:onStatusChange(status) end)
                        end
                    end
                end
            end
            os.sleep(5)
        end
    end)
end

function ConnectionManager:getStats()
    local stats = {
        totalConnections = 0,
        connectionsByProtocol = {},
        totalBytesSent = 0,
        totalBytesReceived = 0,
        totalMessagesSent = 0,
        totalMessagesReceived = 0,
        totalErrors = 0
    }

    for _, data in pairs(self.connections) do
        stats.totalConnections = stats.totalConnections + 1

        local proto = data.protocol
        if not stats.connectionsByProtocol[proto] then
            stats.connectionsByProtocol[proto] = {
                count = 0,
                bytesSent = 0,
                bytesReceived = 0,
                messagesSent = 0,
                messagesReceived = 0,
                errors = 0
            }
        end

        stats.connectionsByProtocol[proto].count = stats.connectionsByProtocol[proto].count + 1
        stats.connectionsByProtocol[proto].bytesSent = stats.connectionsByProtocol[proto].bytesSent + data.stats.bytesSent
        stats.connectionsByProtocol[proto].bytesReceived = stats.connectionsByProtocol[proto].bytesReceived + data.stats.bytesReceived
        stats.connectionsByProtocol[proto].messagesSent = stats.connectionsByProtocol[proto].messagesSent + data.stats.messagesSent
        stats.connectionsByProtocol[proto].messagesReceived = stats.connectionsByProtocol[proto].messagesReceived + data.stats.messagesReceived
        stats.connectionsByProtocol[proto].errors = stats.connectionsByProtocol[proto].errors + data.stats.errors

        stats.totalBytesSent = stats.totalBytesSent + data.stats.bytesSent
        stats.totalBytesReceived = stats.totalBytesReceived + data.stats.bytesReceived
        stats.totalMessagesSent = stats.totalMessagesSent + data.stats.messagesSent
        stats.totalMessagesReceived = stats.totalMessagesReceived + data.stats.messagesReceived
        stats.totalErrors = stats.totalErrors + data.stats.errors
    end

    if self.logger then
        self.logger:debug("Statistics: %d connections, %d bytes sent, %d bytes received, %d errors",
                stats.totalConnections, stats.totalBytesSent, stats.totalBytesReceived, stats.totalErrors)
    end

    return stats
end

function ConnectionManager:resetStats(connId)
    if connId then
        local connectionData = self.connections[connId]
        if connectionData then
            connectionData.stats = {
                bytesSent = 0,
                bytesReceived = 0,
                messagesSent = 0,
                messagesReceived = 0,
                errors = 0
            }

            if self.logger then
                self.logger:debug("Reset statistics for connection %s", connId)
            end

            return true
        else
            return false, error("Connection ID not found")
        end
    else
        for _, data in pairs(self.connections) do
            data.stats = {
                bytesSent = 0,
                bytesReceived = 0,
                messagesSent = 0,
                messagesReceived = 0,
                errors = 0
            }
        end

        if self.logger then
            self.logger:debug("Reset statistics for all connections")
        end

        return true
    end
end

function ConnectionManager:executeProtocolAction(connId, action, ...)
    local connectionData = self.connections[connId]
    if not connectionData then
        local err = "Connection ID not found"
        if self.logger then self.logger:error("ExecuteProtocolAction failed: %s", err) end
        return false, error(err)
    end

    local conn = connectionData.connection
    local protocol = connectionData.protocol

    if self.logger then
        self.logger:debug("Executing action '%s' on %s connection %s", action, protocol, connId)
    end

    if conn[action] then
        return conn[action](conn, ...)
    else
        return false, error(string.format("Action '%s' not supported for protocol '%s'", action, protocol))
    end
end

return ConnectionManager