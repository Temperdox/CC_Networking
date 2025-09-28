-- protocols/mqtt.lua
local PROTOCOL_NAMES = require("protocols.protocol_names") or error("Protocol Names Enum not available")
local STATUSES = require("protocols.statuses") or error("Statuses Enum not available")
local Logger = require("util.logger")

local c_http = http or _G.http or error("HTTP API not available")
local parallel = parallel or _G.parallel or error("parallel API not found")
local sleep = sleep or _G.sleep or os.sleep or function(t) os.sleep(t) end

local MQTT = {}
MQTT.__index = MQTT
MQTT.PROTOCOL_NAME = PROTOCOL_NAMES.mqtt
MQTT.SUPPORTED_METHODS = {
    "connect",
    "publish",
    "subscribe",
    "unsubscribe",
    "disconnect",
    "isConnected",
    "setCallback",
    "poll"
}

-- Create a shared logger for all MQTT instances
MQTT.logger = Logger and Logger:new({
    title = "MQTT Protocol",
    logFile = "logs/mqtt.log",
    maxLogs = 500
}) or nil

local PacketTypes = {
    CONNECT = 1,
    CONNACK = 2,
    PUBLISH = 3,
    PUBACK = 4,
    PUBREC = 5,
    PUBREL = 6,
    PUBCOMP = 7,
    SUBSCRIBE = 8,
    SUBACK = 9,
    UNSUBSCRIBE = 10,
    UNSUBACK = 11,
    PINGREQ = 12,
    PINGRESP = 13,
    DISCONNECT = 14,
    AUTH = 15
}

function MQTT:new(broker, port, options)
    local obj = {}
    setmetatable(obj, self)
    obj.broker = broker
    obj.port = port or 1883
    obj.options = options or {}
    obj.clientId = obj.options.clientId or "cc_mqtt_client_" .. os.getComputerID()
    obj.username = obj.options.username
    obj.password = obj.options.password
    obj.keepAlive = obj.options.keepAlive or 60
    obj.connected = false
    obj.rememberSubscriptions = obj.options.rememberSubscriptions or false
    obj.rememberAuth = obj.options.rememberAuth or false
    obj.socket = nil
    obj.subscriptions = {}
    obj.packetId = 0
    obj.localCandidates = {}
    obj.connections = {}
    obj.callbacks = {
        onMessage = function(topic, message) end,
        onConnect = function() end,
        onDisconnect = function() end,
        onError = function(err) end
    }

    -- Use individual logger if provided, otherwise use shared
    obj.logger = obj.options.logger or MQTT.logger

    if obj.logger then
        obj.logger:info("MQTT client created for broker %s:%d", broker, obj.port)
        obj.logger:debug("Client ID: %s, Keep-alive: %d seconds", obj.clientId, obj.keepAlive)
    end

    return obj
end

function MQTT:connect(username, password)
    username = username or self.username
    password = password or self.password

    if self.logger then
        self.logger:info("Connecting to MQTT broker %s:%d", self.broker, self.port)
        if username then
            self.logger:debug("Using username: %s", username)
        end
    end

    local connectPacket = {
        type = PacketTypes.CONNECT,
        clientId = self.clientId,
        username = username,
        password = password,
        cleanSession = true,
        keepAlive = self.keepAlive
    }

    local response = self:sendPacket(connectPacket)

    if response and response.type == PacketTypes.CONNACK and response.returnCode == 0 then
        self.connected = true

        if self.logger then
            self.logger:info("Successfully connected to MQTT broker")
        end

        self:startKeepAlive()
        self:startReceiveLoop()

        if self.rememberSubscriptions then
            for topic in pairs(self.subscriptions) do
                if self.logger then
                    self.logger:debug("Re-subscribing to remembered topic: %s", topic)
                end
                self:subscribe(topic)
            end
        end

        if self.callbacks.onConnect then
            self.callbacks.onConnect()
        end
        return STATUSES.MQTT.SUCCESS, "Connected to MQTT broker"
    else
        if self.logger then
            self.logger:error("Failed to connect to MQTT broker - Return code: %s",
                    response and response.returnCode or "no response")
        end
        return STATUSES.MQTT.CONNECTION_FAILED, "Failed to connect to MQTT broker"
    end
end

function MQTT:decodePacket(data)
    if not data or #data == 0 then
        if self.logger then
            self.logger:trace("Empty packet received")
        end
        return nil
    end

    -- Try JSON decoding first (for HTTP-based emulation)
    local success, decoded = pcall(function()
        return textutils.unserialiseJSON and textutils.unserialiseJSON(data) or textutils.unserialize(data)
    end)

    if success and decoded then
        if self.logger then
            self.logger:trace("Decoded JSON packet type: %s", decoded.type or "unknown")
        end
        return decoded
    end

    -- Fallback to binary MQTT packet decoding
    local packetType = string.byte(data, 1) >> 4

    if self.logger then
        self.logger:trace("Decoding binary packet type: %d", packetType)
    end

    if packetType == PacketTypes.CONNACK then
        return {
            type = PacketTypes.CONNACK,
            returnCode = #data >= 4 and string.byte(data, 4) or 0
        }
    elseif packetType == PacketTypes.PUBLISH then
        if #data < 5 then return nil end
        local topicLength = (string.byte(data, 3) * 256) + string.byte(data, 4)
        if #data < 4 + topicLength then return nil end
        local topic = data:sub(5, 4 + topicLength)
        local message = data:sub(5 + topicLength)
        return {
            type = PacketTypes.PUBLISH,
            topic = topic,
            message = message
        }
    elseif packetType == PacketTypes.SUBACK then
        return {type = PacketTypes.SUBACK}
    elseif packetType == PacketTypes.UNSUBACK then
        return {type = PacketTypes.UNSUBACK}
    elseif packetType == PacketTypes.PINGRESP then
        return {type = PacketTypes.PINGRESP}
    elseif packetType == PacketTypes.PUBACK then
        return {type = PacketTypes.PUBACK}
    end

    return nil
end

function MQTT:encodePacket(packet)
    -- For HTTP-based emulation, use JSON encoding
    if self.options.useHTTP then
        local encoded = textutils.serialiseJSON and textutils.serialiseJSON(packet) or textutils.serialize(packet)
        if self.logger then
            self.logger:trace("Encoded packet as JSON: %d bytes", #encoded)
        end
        return encoded
    end

    -- Binary MQTT packet encoding
    local encoded = ""

    if packet.type == PacketTypes.CONNECT then
        local flags = 0x00
        if packet.username then flags = flags + 0x80 end
        if packet.password then flags = flags + 0x40 end
        if packet.cleanSession then flags = flags + 0x02 end

        local payload = string.char(0, #packet.clientId) .. packet.clientId
        if packet.username then
            payload = payload .. string.char(0, #packet.username) .. packet.username
        end
        if packet.password then
            payload = payload .. string.char(0, #packet.password) .. packet.password
        end

        local variableHeader = string.char(0, 4) .. "MQTT" .. string.char(4, flags)
        variableHeader = variableHeader .. string.char((packet.keepAlive >> 8) % 256, packet.keepAlive % 256)

        local remainingLength = #variableHeader + #payload
        local fixedHeader = string.char(PacketTypes.CONNECT * 16) .. string.char(remainingLength % 256)

        encoded = fixedHeader .. variableHeader .. payload

    elseif packet.type == PacketTypes.PUBLISH then
        local topicLength = #packet.topic
        local qos = packet.qos or 0
        local retain = packet.retain and 1 or 0
        local flags = (qos * 2) + retain

        local variableHeader = string.char((topicLength >> 8) % 256, topicLength % 256) .. packet.topic
        if qos > 0 then
            variableHeader = variableHeader .. string.char((packet.packetId >> 8) % 256, packet.packetId % 256)
        end

        local payload = packet.message or ""
        local remainingLength = #variableHeader + #payload
        local fixedHeader = string.char(PacketTypes.PUBLISH * 16 + flags) .. string.char(remainingLength % 256)

        encoded = fixedHeader .. variableHeader .. payload

    elseif packet.type == PacketTypes.SUBSCRIBE then
        local variableHeader = string.char((packet.packetId >> 8) % 256, packet.packetId % 256)
        local payload = ""

        for i, topic in ipairs(packet.topics) do
            local qos = packet.qos and packet.qos[i] or 0
            payload = payload .. string.char(0, #topic) .. topic .. string.char(qos)
        end

        local remainingLength = #variableHeader + #payload
        local fixedHeader = string.char(PacketTypes.SUBSCRIBE * 16 + 2) .. string.char(remainingLength % 256)

        encoded = fixedHeader .. variableHeader .. payload

    elseif packet.type == PacketTypes.UNSUBSCRIBE then
        local variableHeader = string.char((packet.packetId >> 8) % 256, packet.packetId % 256)
        local payload = ""

        for _, topic in ipairs(packet.topics) do
            payload = payload .. string.char(0, #topic) .. topic
        end

        local remainingLength = #variableHeader + #payload
        local fixedHeader = string.char(PacketTypes.UNSUBSCRIBE * 16 + 2) .. string.char(remainingLength % 256)

        encoded = fixedHeader .. variableHeader .. payload

    elseif packet.type == PacketTypes.PINGREQ then
        encoded = string.char(PacketTypes.PINGREQ * 16, 0)

    elseif packet.type == PacketTypes.DISCONNECT then
        encoded = string.char(PacketTypes.DISCONNECT * 16, 0)
    end

    if self.logger then
        self.logger:trace("Encoded binary packet: %d bytes", #encoded)
    end

    return encoded
end

function MQTT:sendPacket(packet)
    local url = string.format("http://%s:%d/mqtt/send", self.broker, self.port)
    local encodedPacket = self:encodePacket(packet)

    if self.logger then
        self.logger:trace("Sending packet to %s", url)
    end

    local success, response = pcall(function()
        return c_http.post(url, encodedPacket)
    end)

    if success and response then
        local responseData = response.readAll()
        response.close()
        if self.logger then
            self.logger:trace("Packet sent, response received")
        end
        return self:decodePacket(responseData)
    else
        if self.logger then
            self.logger:warn("Failed to send packet: %s", tostring(response))
        end
    end

    return nil
end

function MQTT:receivePacket()
    local url = string.format("http://%s:%d/mqtt/receive", self.broker, self.port)

    local success, response = pcall(function()
        return c_http.get(url)
    end)

    if success and response then
        local data = response.readAll()
        response.close()
        return self:decodePacket(data)
    end

    return nil
end

function MQTT:publish(topic, message, qos, retain)
    if not self.connected then
        if self.logger then
            self.logger:warn("Cannot publish: not connected to broker")
        end
        return STATUSES.MQTT.NOT_CONNECTED, "Not connected to MQTT broker"
    end

    self.packetId = (self.packetId % 65535) + 1

    if self.logger then
        self.logger:info("Publishing to topic '%s' (QoS: %d, Retain: %s)",
                topic, qos or 0, tostring(retain or false))
        self.logger:debug("Message: %s", tostring(message))
    end

    local publishPacket = {
        type = PacketTypes.PUBLISH,
        topic = topic,
        message = message,
        qos = qos or 0,
        retain = retain or false,
        packetId = self.packetId
    }

    local response = self:sendPacket(publishPacket)

    if qos == 1 then
        if response and response.type == PacketTypes.PUBACK then
            if self.logger then
                self.logger:debug("Publish acknowledged (QoS 1)")
            end
            return STATUSES.MQTT.SUCCESS
        else
            if self.logger then
                self.logger:warn("Publish not acknowledged (QoS 1)")
            end
            return STATUSES.MQTT.CONNECTION_FAILED
        end
    end

    return STATUSES.MQTT.SUCCESS, "Message published"
end

function MQTT:subscribe(topic, qos)
    if not self.connected then
        if self.logger then
            self.logger:warn("Cannot subscribe: not connected to broker")
        end
        return STATUSES.MQTT.NOT_CONNECTED, "Not connected to MQTT broker"
    end

    self.packetId = (self.packetId % 65535) + 1

    if self.logger then
        self.logger:info("Subscribing to topic '%s' (QoS: %d)", topic, qos or 0)
    end

    local subscribePacket = {
        type = PacketTypes.SUBSCRIBE,
        topics = {topic},
        qos = {qos or 0},
        packetId = self.packetId
    }

    local response = self:sendPacket(subscribePacket)

    if response and response.type == PacketTypes.SUBACK then
        self.subscriptions[topic] = true
        if self.logger then
            self.logger:info("Successfully subscribed to topic '%s'", topic)
        end
        return STATUSES.MQTT.SUCCESS, "Subscribed to topic"
    else
        if self.logger then
            self.logger:error("Failed to subscribe to topic '%s'", topic)
        end
        return STATUSES.MQTT.SUBSCRIPTION_FAILED, "Failed to subscribe to topic"
    end
end

function MQTT:unsubscribe(topic)
    if not self.connected then
        if self.logger then
            self.logger:warn("Cannot unsubscribe: not connected to broker")
        end
        return STATUSES.MQTT.NOT_CONNECTED, "Not connected to MQTT broker"
    end

    self.packetId = (self.packetId % 65535) + 1

    if self.logger then
        self.logger:info("Unsubscribing from topic '%s'", topic)
    end

    local unsubscribePacket = {
        type = PacketTypes.UNSUBSCRIBE,
        topics = {topic},
        packetId = self.packetId
    }

    local response = self:sendPacket(unsubscribePacket)

    if response and response.type == PacketTypes.UNSUBACK then
        self.subscriptions[topic] = nil
        if self.logger then
            self.logger:info("Successfully unsubscribed from topic '%s'", topic)
        end
        return STATUSES.MQTT.SUCCESS, "Unsubscribed from topic"
    else
        if self.logger then
            self.logger:error("Failed to unsubscribe from topic '%s'", topic)
        end
        return STATUSES.MQTT.UNSUBSCRIPTION_FAILED, "Failed to unsubscribe from topic"
    end
end

function MQTT:startKeepAlive()
    if self.logger then
        self.logger:debug("Starting keep-alive timer (interval: %d seconds)", self.keepAlive * 0.75)
    end

    parallel.waitForAny(function()
        while self.connected do
            sleep(self.keepAlive * 0.75)

            if self.connected then
                if self.logger then
                    self.logger:trace("Sending PINGREQ")
                end
                local packet = {type = PacketTypes.PINGREQ}
                self:sendPacket(packet)
            end
        end
    end)
end

function MQTT:startReceiveLoop()
    if self.logger then
        self.logger:debug("Starting receive loop")
    end

    parallel.waitForAny(function()
        while self.connected do
            local packet = self:receivePacket()

            if packet then
                if packet.type == PacketTypes.PUBLISH then
                    if self.logger then
                        self.logger:info("Message received on topic '%s'", packet.topic)
                        self.logger:debug("Message content: %s", packet.message)
                    end
                    if self.callbacks.onMessage then
                        self.callbacks.onMessage(packet.topic, packet.message)
                    end
                elseif packet.type == PacketTypes.PINGREQ then
                    if self.logger then
                        self.logger:trace("PINGREQ received, sending PINGRESP")
                    end
                    self:sendPacket({type = PacketTypes.PINGRESP})
                elseif packet.type == PacketTypes.DISCONNECT then
                    if self.logger then
                        self.logger:info("DISCONNECT received from broker")
                    end
                    self.connected = false
                    if self.callbacks.onDisconnect then
                        self.callbacks.onDisconnect()
                    end
                    break
                end
            end

            sleep(0.1)
        end

        if not self.connected and self.callbacks.onDisconnect then
            if self.logger then
                self.logger:info("Connection lost, calling onDisconnect callback")
            end
            self.callbacks.onDisconnect()
        end
    end)
end

function MQTT:on(event, callback)
    if event == "message" then
        self.callbacks.onMessage = callback
    elseif event == "connect" then
        self.callbacks.onConnect = callback
    elseif event == "disconnect" then
        self.callbacks.onDisconnect = callback
    elseif event == "error" then
        self.callbacks.onError = callback
    else
        if self.logger then
            self.logger:warn("Invalid event name: %s", event)
        end
        return STATUSES.MQTT.INVALID_EVENT, "Invalid event: " .. event
    end

    if self.logger then
        self.logger:debug("Callback set for event: %s", event)
    end

    return STATUSES.MQTT.SUCCESS, "Callback set for " .. event
end

function MQTT:disconnect()
    if not self.connected then
        if self.logger then
            self.logger:warn("Already disconnected from broker")
        end
        return STATUSES.MQTT.NOT_CONNECTED, "Not connected to MQTT broker"
    end

    if self.logger then
        self.logger:info("Disconnecting from MQTT broker")
    end

    local disconnectPacket = {type = PacketTypes.DISCONNECT}
    self:sendPacket(disconnectPacket)
    self.connected = false

    if self.callbacks.onDisconnect then
        self.callbacks.onDisconnect()
    end

    if self.logger then
        self.logger:info("Disconnected from MQTT broker")
    end

    return STATUSES.MQTT.SUCCESS, "Disconnected from MQTT broker"
end

function MQTT:close()
    if self.socket then
        self.socket.close()
        self.socket = nil
    end
    self.connected = false

    if self.logger then
        self.logger:debug("Socket closed")
    end

    return STATUSES.MQTT.SUCCESS, "Socket closed"
end

function MQTT:checkStatus()
    return self.connected and STATUSES.mqtt_subscribed or STATUSES.disconnected
end

function MQTT:isConnected()
    return self.connected
end

return MQTT