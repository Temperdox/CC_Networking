-- protocols/webrtc.lua
local PROTOCOL_NAMES = require("protocols.protocol_names") or error("Protocol Names Enum not available")
local STATUSES = require("protocols.statuses") or error("Statuses Enum not available")
local Logger = require("util.logger")

local c_http = http or _G.http or require("protocols.http_client") or error("HTTP API not available")
local parallel = parallel or _G.parallel or error("parallel API not found")
local sleep = sleep or _G.sleep or os.sleep or function(t) os.sleep(t) end

local WebRTC = {}
WebRTC.__index = WebRTC
WebRTC.PROTOCOL_NAME = PROTOCOL_NAMES.webrtc

WebRTC.SUPPORTED_METHODS = {
    "connect",
    "send",
    "receive",
    "close",
    "poll",
    "connectToPeer",
    "createDataChannel",
    "sendData",
    "getStats",
    "closePeerConnection",
    "createOffer",
    "createAnswer",
}

-- Create a shared logger for all WebRTC instances
WebRTC.logger = Logger and Logger:new({
    title = "WebRTC Protocol",
    logFile = "logs/webrtc.log",
    maxLogs = 500
}) or nil

function WebRTC:new(peerId, options)
    local obj = {}
    setmetatable(obj, self)

    obj.peerId = peerId
    obj.options = options or {}
    obj.connections = {}
    obj.dataChannels = {}
    obj.signalingServer = options.signalingServer
    obj.callbacks = {
        onOpen = options.onOpen or function() end,
        onClose = options.onClose or function() end,
        onError = options.onError or function() end,
        onMessage = options.onMessage or function() end,
        onPeerConnected = options.onPeerConnected or function() end,
        onPeerDisconnected = options.onPeerDisconnected or function() end,
    }
    obj.iceServers = options.iceServers or {}
    obj.connected = false
    obj.dataChannel = nil
    obj.localCandidates = {}
    obj.keepAliveTimer = nil

    -- Use individual logger if provided, otherwise use shared
    obj.logger = options.logger or WebRTC.logger

    if obj.logger then
        obj.logger:info("WebRTC instance created with peer ID: %s", peerId)
        if obj.signalingServer then
            obj.logger:debug("Signaling server: %s", obj.signalingServer)
        end
        if #obj.iceServers > 0 then
            obj.logger:debug("ICE servers configured: %d", #obj.iceServers)
        end
    end

    obj:initialize()

    return obj
end

function WebRTC:initialize()
    if self.logger then
        self.logger:debug("Initializing WebRTC connection")
    end

    self:gatherICECandidates()

    if self.signalingServer then
        local status, err = self:connectToSignalingServer()
        if not status then
            if self.logger then
                self.logger:error("Failed to connect to signaling server: %s", err or "unknown error")
            end
            self.callbacks.onError(err or "Failed to connect to signaling server")
            return
        end
    else
        if self.logger then
            self.logger:error("No signaling server provided")
        end
        self.callbacks.onError("No signaling server provided")
        return
    end

    if self.logger then
        self.logger:info("WebRTC initialized successfully for peer ID: %s", self.peerId)
    end
end

function WebRTC:gatherICECandidates()
    self.localCandidates = {}

    -- Add local host candidate
    table.insert(self.localCandidates, {
        type = "host",
        address = "local:" .. os.getComputerID(),
        priority = 1000,
        protocol = "udp"
    })

    if self.logger then
        self.logger:debug("Added host ICE candidate: local:%d", os.getComputerID())
    end

    if self.iceServers then
        for _, server in ipairs(self.iceServers) do
            if server.url and server.url:match("^stun:") then
                table.insert(self.localCandidates, {
                    type = "srflx",
                    address = server.url,
                    priority = 800,
                    protocol = "udp"
                })

                if self.logger then
                    self.logger:debug("Added STUN server candidate: %s", server.url)
                end
            elseif server.url and server.url:match("^turn:") then
                table.insert(self.localCandidates, {
                    type = "relay",
                    address = server.url,
                    priority = 600,
                    protocol = "udp"
                })

                if self.logger then
                    self.logger:debug("Added TURN relay candidate: %s", server.url)
                end
            end
        end
    end

    if self.logger then
        self.logger:info("Gathered %d ICE candidates", #self.localCandidates)
    end
end

function WebRTC:createOffer()
    if self.logger then
        self.logger:debug("Creating WebRTC offer")
    end

    local offer = {
        type = "offer",
        sdp = textutils.serialiseJSON and textutils.serialiseJSON({
            candidates = self.localCandidates,
            peerId = self.peerId,
            timestamp = os.epoch and os.epoch("utc") or os.time(),
            capabilities = {
                audio = false,
                video = false,
                data = true
            }
        }) or textutils.serialize({
            candidates = self.localCandidates,
            peerId = self.peerId,
            timestamp = os.time(),
            capabilities = {
                audio = false,
                video = false,
                data = true
            }
        })
    }

    if self.logger then
        self.logger:trace("Offer created with SDP length: %d", #offer.sdp)
    end

    return offer
end

function WebRTC:createAnswer(offer)
    if self.logger then
        self.logger:debug("Creating WebRTC answer to offer from peer")
    end

    local answer = {
        type = "answer",
        sdp = textutils.serialiseJSON and textutils.serialiseJSON({
            candidates = self.localCandidates,
            peerId = self.peerId,
            timestamp = os.epoch and os.epoch("utc") or os.time(),
            offerAccepted = true
        }) or textutils.serialize({
            candidates = self.localCandidates,
            peerId = self.peerId,
            timestamp = os.time(),
            offerAccepted = true
        })
    }

    if self.logger then
        self.logger:trace("Answer created with SDP length: %d", #answer.sdp)
    end

    return answer
end

function WebRTC:connectToPeer(remotePeerId, offer)
    if self.logger then
        self.logger:info("Connecting to peer: %s", remotePeerId)
        if offer then
            self.logger:debug("Using provided offer for connection")
        else
            self.logger:debug("Creating new offer for connection")
        end
    end

    local connection = {
        remotePeerId = remotePeerId,
        state = STATUSES.WEBRTC.CONNECTING,
        dataChannels = {},
        stats = {
            bytesSent = 0,
            bytesReceived = 0,
            packetsSent = 0,
            packetsReceived = 0,
            connectionStartTime = os.epoch and os.epoch("utc") or os.time(),
            lastPacketSentTime = nil,
            lastPacketReceivedTime = nil
        }
    }

    self.connections[remotePeerId] = connection

    if offer then
        local answer = self:createAnswer(offer)
        self:sendSignalingMessage(remotePeerId, answer)

        if self.logger then
            self.logger:debug("Sent answer to peer %s", remotePeerId)
        end
    else
        local newOffer = self:createOffer()
        self:sendSignalingMessage(remotePeerId, newOffer)

        if self.logger then
            self.logger:debug("Sent offer to peer %s", remotePeerId)
        end
    end

    connection.state = STATUSES.WEBRTC.CONNECTED
    self.connected = true

    if self.logger then
        self.logger:info("Connected to peer %s successfully", remotePeerId)
    end

    self.callbacks.onPeerConnected(remotePeerId)

    return connection
end

function WebRTC:createDataChannel(peerId, label, options)
    local connection = self.connections[peerId]
    if not connection or connection.state ~= STATUSES.WEBRTC.CONNECTED then
        if self.logger then
            self.logger:warn("Cannot create data channel: no active connection to peer %s", peerId)
        end
        return nil, "No active connection to peer " .. peerId
    end

    options = options or {}
    label = label or "dataChannel"

    if self.logger then
        self.logger:info("Creating data channel '%s' for peer %s", label, peerId)
        self.logger:debug("Channel options: ordered=%s, maxRetransmits=%d",
                tostring(options.ordered ~= false), options.maxRetransmits or 3)
    end

    local dataChannel = {
        label = label,
        state = STATUSES.WEBRTC.DATA_CHANNEL.CLOSED,
        buffer = {},
        ordered = options.ordered ~= false,
        maxRetransmits = options.maxRetransmits or 3,
        protocol = options.protocol or "",
        retransmitCount = 0
    }

    connection.dataChannels[label] = dataChannel
    dataChannel.state = STATUSES.WEBRTC.DATA_CHANNEL.OPEN

    if self.logger then
        self.logger:info("Data channel '%s' opened for peer %s", label, peerId)
    end

    return dataChannel
end

function WebRTC:sendData(peerId, label, data)
    local connection = self.connections[peerId]
    if not connection or connection.state ~= STATUSES.WEBRTC.CONNECTED then
        if self.logger then
            self.logger:warn("Cannot send data: no active connection to peer %s", peerId)
        end
        return STATUSES.WEBRTC.NOT_CONNECTED, "No active connection to peer " .. peerId
    end

    local dataChannel = connection.dataChannels[label]
    if not dataChannel or dataChannel.state ~= STATUSES.WEBRTC.DATA_CHANNEL.OPEN then
        if self.logger then
            self.logger:warn("Cannot send data: channel '%s' not open for peer %s", label, peerId)
        end
        return STATUSES.WEBRTC.DATA_CHANNEL.NOT_OPEN, "Data channel " .. label .. " is not open"
    end

    local packet = {
        from = self.peerId,
        to = peerId,
        label = label,
        data = data,
        timestamp = os.epoch and os.epoch("utc") or os.time(),
        seq = #dataChannel.buffer + 1
    }

    table.insert(dataChannel.buffer, packet)

    local serializedData = textutils.serialise and textutils.serialise(data) or textutils.serialize(data)
    connection.stats.bytesSent = connection.stats.bytesSent + #serializedData

    if self.logger then
        self.logger:debug("Sending %d bytes to peer %s on channel '%s'", #serializedData, peerId, label)
        self.logger:trace("Packet sequence: %d", packet.seq)
    end

    if self.signalingServer then
        self:sendSignalingMessage(peerId, packet)
        connection.stats.packetsSent = connection.stats.packetsSent + 1
        connection.stats.lastPacketSentTime = os.epoch and os.epoch("utc") or os.time()

        if self.logger then
            self.logger:trace("Packet sent successfully - Total sent: %d", connection.stats.packetsSent)
        end

        return STATUSES.WEBRTC.DATA_CHANNEL.SENT, "Data sent on channel " .. label
    else
        if self.logger then
            self.logger:error("Cannot send data: not connected to signaling server")
        end
        return STATUSES.WEBRTC.SIGNALING_SERVER_NOT_CONNECTED, "Not connected to signaling server"
    end
end

function WebRTC:connectToSignalingServer()
    if self.logger then
        self.logger:info("Connecting to signaling server: %s", self.signalingServer)
    end

    local success = true

    parallel.waitForAny(
            function()
                while true do
                    local url = self.signalingServer .. "/poll?peerId=" .. self.peerId

                    if self.logger then
                        self.logger:trace("Polling signaling server: %s", url)
                    end

                    local pollSuccess, response = pcall(function()
                        return c_http.get(url)
                    end)

                    if pollSuccess and response then
                        local message = response.readAll()
                        response.close()
                        if message and message ~= "" and #message > 0 then
                            local decoded = textutils.unserialiseJSON and textutils.unserialiseJSON(message) or textutils.unserialize(message)
                            if decoded then
                                if self.logger then
                                    self.logger:trace("Received signaling message from server")
                                end
                                self:handleSignalingMessage(decoded)
                            end
                        end
                    else
                        if self.logger then
                            self.logger:warn("Failed to poll signaling server: %s", tostring(response))
                        end
                        self.callbacks.onError("Failed to poll signaling server")
                    end
                    sleep(1)
                end
            end,
            function()
                self:sendKeepAlive()
            end
    )

    if self.logger then
        self.logger:info("Connected to signaling server successfully")
    end

    return success
end

function WebRTC:sendKeepAlive()
    if self.logger then
        self.logger:debug("Starting keep-alive thread")
    end

    while self.connected do
        sleep(30) -- Send keepalive every 30 seconds

        if self.signalingServer then
            local url = self.signalingServer .. "/keepalive"
            local payload = textutils.serialiseJSON and textutils.serialiseJSON({
                peerId = self.peerId,
                connections = #self.connections
            }) or textutils.serialize({
                peerId = self.peerId,
                connections = #self.connections
            })

            if self.logger then
                self.logger:trace("Sending keep-alive to signaling server")
            end

            local success, response = pcall(function()
                return c_http.post(url, payload)
            end)

            if success and response then
                response.close()
                if self.logger then
                    self.logger:trace("Keep-alive sent successfully")
                end
            else
                if self.logger then
                    self.logger:warn("Failed to send keep-alive: %s", tostring(response))
                end
            end
        end
    end
end

function WebRTC:handleSignalingMessage(message)
    if self.logger then
        self.logger:debug("Handling signaling message type: %s", message.type or "unknown")
    end

    if self.callbacks.onMessage then
        self.callbacks.onMessage(message)
    end

    -- Handle specific message types
    if message.type == "offer" then
        if self.logger then
            self.logger:info("Received offer from peer %s", message.from or "unknown")
        end
        -- Auto-accept offers if configured
        if self.options.autoAccept and message.from then
            self:connectToPeer(message.from, message)
        end
    elseif message.type == "answer" then
        if self.logger then
            self.logger:info("Received answer from peer %s", message.from or "unknown")
        end
    elseif message.type == "ice" then
        if self.logger then
            self.logger:debug("Received ICE candidate from peer %s", message.from or "unknown")
        end
    elseif message.type == "data" then
        if self.logger then
            self.logger:trace("Received data message from peer %s", message.from or "unknown")
        end
        if message.from and self.connections[message.from] then
            local connection = self.connections[message.from]
            connection.stats.bytesReceived = connection.stats.bytesReceived + #textutils.serialize(message.data)
            connection.stats.packetsReceived = connection.stats.packetsReceived + 1
            connection.stats.lastPacketReceivedTime = os.epoch and os.epoch("utc") or os.time()
        end
    end
end

function WebRTC:sendSignalingMessage(toPeerId, message)
    if self.logger then
        self.logger:debug("Sending signaling message to peer %s", toPeerId)
    end

    local url = self.signalingServer .. "/message"
    local payload = textutils.serialiseJSON and textutils.serialiseJSON({
        from = self.peerId,
        to = toPeerId,
        message = message
    }) or textutils.serialize({
        from = self.peerId,
        to = toPeerId,
        message = message
    })

    local success, response = pcall(function()
        return c_http.post(url, payload)
    end)

    if success and response then
        response.close()
        if self.logger then
            self.logger:trace("Signaling message sent successfully to %s", toPeerId)
        end
        return true
    else
        if self.logger then
            self.logger:error("Failed to send signaling message to %s: %s", toPeerId, tostring(response))
        end
        self.callbacks.onError("Failed to send signaling message")
        return false
    end
end

function WebRTC:send(data)
    if not self.connected then
        if self.logger then
            self.logger:warn("Cannot send: no active connections")
        end
        return STATUSES.WEBRTC.NOT_CONNECTED, "No active connections"
    end

    local label = "default"
    local successCount = 0
    local totalPeers = 0

    for peerId, connection in pairs(self.connections) do
        totalPeers = totalPeers + 1
        local status, err = self:sendData(peerId, label, data)
        if status == STATUSES.WEBRTC.DATA_CHANNEL.SENT then
            successCount = successCount + 1
        else
            if self.logger then
                self.logger:warn("Failed to send to peer %s: %s", peerId, err)
            end
        end
    end

    if self.logger then
        self.logger:info("Broadcast complete: sent to %d/%d peers", successCount, totalPeers)
    end

    if successCount == totalPeers then
        return STATUSES.WEBRTC.DATA_CHANNEL.SENT, "Data sent to all connected peers"
    elseif successCount > 0 then
        return STATUSES.WEBRTC.DATA_CHANNEL.SENT, string.format("Data sent to %d/%d peers", successCount, totalPeers)
    else
        return STATUSES.WEBRTC.DATA_CHANNEL.NOT_OPEN, "Failed to send to any peers"
    end
end

function WebRTC:sendDataToPeer(peerId, channel, data)
    return self:sendData(peerId, channel, data)
end

function WebRTC:sendDataToAllPeers(channel, data)
    local allSuccess = true
    local lastError = nil
    local successCount = 0
    local totalPeers = 0

    if self.logger then
        self.logger:info("Broadcasting data to all peers on channel '%s'", channel)
    end

    for peerId, connection in pairs(self.connections) do
        totalPeers = totalPeers + 1
        local status, err = self:sendData(peerId, channel, data)
        if status == STATUSES.WEBRTC.DATA_CHANNEL.SENT then
            successCount = successCount + 1
        else
            allSuccess = false
            lastError = err
        end
    end

    if self.logger then
        self.logger:info("Broadcast complete: %d/%d successful", successCount, totalPeers)
    end

    if allSuccess then
        return STATUSES.WEBRTC.DATA_CHANNEL.SENT, "Data sent to all peers"
    else
        return STATUSES.WEBRTC.DATA_CHANNEL.NOT_OPEN, lastError or "Failed to send to some peers"
    end
end

function WebRTC:getStats()
    local stats = {}
    for peerId, connection in pairs(self.connections) do
        stats[peerId] = connection.stats
    end

    if self.logger then
        self.logger:debug("Retrieved statistics for %d connections", #stats)
    end

    return stats
end

function WebRTC:getStatsFromPeer(peerId)
    local connection = self.connections[peerId]
    if connection then
        if self.logger then
            self.logger:trace("Retrieved stats for peer %s - Sent: %d bytes, Received: %d bytes",
                    peerId, connection.stats.bytesSent, connection.stats.bytesReceived)
        end
        return connection.stats
    else
        if self.logger then
            self.logger:warn("No connection found for peer %s", peerId)
        end
        return nil, "No connection found for peer " .. peerId
    end
end

function WebRTC:on(event, callback)
    if self.callbacks[event] then
        self.callbacks[event] = callback
        if self.logger then
            self.logger:debug("Callback set for event: %s", event)
        end
        return true
    else
        if self.logger then
            self.logger:warn("Invalid event name: %s", event)
        end
        return false, "Invalid event: " .. event
    end
end

function WebRTC:checkStatus()
    if self.connected then
        return STATUSES.webrtc_ice
    else
        return STATUSES.disconnected
    end
end

function WebRTC:close()
    if self.logger then
        self.logger:info("Closing all WebRTC connections")
    end

    local closedCount = 0
    for peerId, connection in pairs(self.connections) do
        connection.state = STATUSES.WEBRTC.CLOSED
        for label, dataChannel in pairs(connection.dataChannels) do
            dataChannel.state = STATUSES.WEBRTC.DATA_CHANNEL.CLOSED
        end
        closedCount = closedCount + 1

        if self.logger then
            self.logger:debug("Closed connection to peer %s", peerId)
        end
    end

    self.connections = {}
    self.connected = false

    if self.logger then
        self.logger:info("Closed %d connections", closedCount)
    end

    if self.callbacks.onClose then
        self.callbacks.onClose()
    end

    return STATUSES.WEBRTC.CLOSED, "All connections closed"
end

function WebRTC:closePeerConnection(peerId)
    local connection = self.connections[peerId]
    if connection then
        if self.logger then
            self.logger:info("Closing connection to peer %s", peerId)
        end

        connection.state = STATUSES.WEBRTC.CLOSED
        for label, dataChannel in pairs(connection.dataChannels) do
            dataChannel.state = STATUSES.WEBRTC.DATA_CHANNEL.CLOSED
            if self.logger then
                self.logger:debug("Closed data channel '%s' for peer %s", label, peerId)
            end
        end

        self.connections[peerId] = nil

        if self.logger then
            self.logger:info("Connection to peer %s closed successfully", peerId)
        end

        self.callbacks.onPeerDisconnected(peerId)

        if self.callbacks.onClose then
            self.callbacks.onClose(peerId)
        end

        return STATUSES.WEBRTC.CLOSED, "Connection to peer " .. peerId .. " closed"
    else
        if self.logger then
            self.logger:warn("No active connection to peer %s", peerId)
        end
        return STATUSES.WEBRTC.NOT_CONNECTED, "No active connection to peer " .. peerId
    end
end

-- Compatibility method for connection manager
function WebRTC:connect()
    -- WebRTC connections are peer-to-peer, this is a placeholder
    if self.logger then
        self.logger:debug("Connect called (no-op for P2P protocol)")
    end
    return self.connected
end

return WebRTC