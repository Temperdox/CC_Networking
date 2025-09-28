-- protocols/tcp.lua
local PROTOCOL_NAMES = require("protocols.protocol_names") or error("Protocol Names Enum not available")
local STATUSES = require("protocols.statuses") or error("Statuses Enum not available")
local Logger = require("util.logger")

local c_http = http or _G.http or error("HTTP API not available")
local parallel = parallel or _G.parallel or error("parallel API not found")
local sleep = sleep or _G.sleep or os.sleep or function(t) os.sleep(t) end

local TCP = {}
TCP.__index = TCP
TCP.PROTOCOL_NAME = PROTOCOL_NAMES.tcp
TCP.SUPPORTED_METHODS = {
    "connect",
    "send",
    "receive",
    "close",
    "isConnected",
    "setTimeout",
    "getTimeout",
    "setKeepAlive",
    "getKeepAlive",
    "setNoDelay",
    "getNoDelay",
    "setBufferSize",
    "getBufferSize",
    "setAddress",
    "getAddress",
}

-- Create a shared logger for all TCP instances
TCP.logger = Logger and Logger:new({
    title = "TCP Protocol",
    logFile = "logs/tcp.log",
    maxLogs = 500
}) or nil

function TCP:new(host, port, options)
    local obj = {}
    setmetatable(obj, self)

    obj.host = host
    obj.port = port
    obj.options = options or {}
    obj.status = STATUSES.TCP.DISCONNECTED
    obj.connected = false
    obj.sequenceNumber = 0
    obj.ackNumber = 0
    obj.windowSize = options.windowSize or 65536
    obj.buffer = {}
    obj.socket = nil
    obj.timeout = obj.options.timeout or 5
    obj.keepAlive = obj.options.keepAlive or false
    obj.keepAliveTimer = nil
    obj.noDelay = obj.options.noDelay or false
    obj.bufferSize = obj.options.bufferSize or 1024
    obj.callbacks = {
        onConnect = obj.options.onConnect or function() end,
        onData = obj.options.onData or function(data) end,
        onClose = obj.options.onClose or function() end,
        onError = obj.options.onError or function(err) end,
    }

    -- Use individual logger if provided, otherwise use shared
    obj.logger = obj.options.logger or TCP.logger

    if obj.logger then
        obj.logger:info("TCP instance created for %s:%d", host, port)
        obj.logger:debug("Options: timeout=%d, keepAlive=%s, windowSize=%d, bufferSize=%d",
                obj.timeout, tostring(obj.keepAlive), obj.windowSize, obj.bufferSize)
    end

    return obj
end

function TCP:connect()
    if self.logger then self.logger:info("Initiating TCP connection to %s:%d", self.host, self.port) end

    self.status = STATUSES.TCP.SYN_SENT
    if self.logger then self.logger:debug("Status: SYN_SENT") end

    local syn = self:createPacket("SYN", nil)
    self:sendPacket(syn)

    sleep(0.01)
    local response, err = self:receivePacket(self.timeout)

    if not response then
        self.status = STATUSES.TCP.DISCONNECTED
        self.connected = false
        if self.logger then self.logger:error("Connection timeout: %s", err or "unknown error") end
        return STATUSES.TCP.CONNECTION_FAILED, "Connection timed out: " .. (err or "unknown error")
    end

    if response.flags and response.flags.SYN and response.flags.ACK and response.ackNumber == self.sequenceNumber + 1 then
        self.ackNumber = response.sequenceNumber + 1
        self.status = STATUSES.TCP.ESTABLISHED
        self.connected = true

        if self.logger then
            self.logger:info("TCP connection established to %s:%d", self.host, self.port)
            self.logger:debug("Status: ESTABLISHED, SeqNum: %d, AckNum: %d", self.sequenceNumber, self.ackNumber)
        end

        local ack = self:createPacket("ACK", nil)
        self:sendPacket(ack)

        if self.keepAlive then
            self:startKeepAlive()
        end

        self.callbacks.onConnect()
        self:startReceiveLoop()

        return STATUSES.TCP.CONNECTED, "Connection established"
    else
        self.status = STATUSES.TCP.DISCONNECTED
        self.connected = false
        if self.logger then self.logger:error("Invalid response from server during handshake") end
        return STATUSES.TCP.CONNECTION_FAILED, "Invalid response from server"
    end
end

function TCP:createPacket(flags, data)
    local packet = {
        sequenceNumber = self.sequenceNumber,
        ackNumber = self.ackNumber,
        flags = {
            SYN = flags:find("SYN") and true or false,
            ACK = flags:find("ACK") and true or false,
            FIN = flags:find("FIN") and true or false,
            PSH = flags:find("PSH") and true or false,
            RST = flags:find("RST") and true or false,
            URG = flags:find("URG") and true or false,
        },
        windowSize = self.windowSize,
        data = data or "",
        timestamp = os.epoch and os.epoch("utc") or os.time()
    }

    if self.logger then
        self.logger:trace("Created packet: Flags=%s, SeqNum=%d, AckNum=%d, DataLen=%d",
                flags, packet.sequenceNumber, packet.ackNumber, #packet.data)
    end

    return packet
end

function TCP:sendPacket(packet)
    local url = string.format("http://%s:%d/tcp", self.host, self.port)
    local serialized = textutils.serialiseJSON and textutils.serialiseJSON(packet) or textutils.serialize(packet)

    if self.logger then
        self.logger:trace("Sending packet to %s", url)
    end

    local success, response = pcall(function()
        return c_http.post(url, serialized)
    end)

    if success and response then
        response.close()
        if self.logger then self.logger:trace("Packet sent successfully") end
    elseif self.logger then
        self.logger:warn("Failed to send packet: %s", tostring(response))
    end

    if packet.data and #packet.data > 0 then
        self.sequenceNumber = self.sequenceNumber + #packet.data
    else
        self.sequenceNumber = self.sequenceNumber + 1
    end
end

function TCP:send(data)
    if not self.connected then
        if self.logger then self.logger:warn("Cannot send data: not connected") end
        return false, "Not connected"
    end

    if self.logger then self.logger:debug("Sending %d bytes of data", #data) end

    -- Fragment data if needed
    local maxSegmentSize = self.options.mss or 1460
    local offset = 1
    local fragments = 0

    while offset <= #data do
        local chunk = data:sub(offset, offset + maxSegmentSize - 1)
        local packet = self:createPacket("PSH,ACK", chunk)
        self:sendPacket(packet)
        offset = offset + maxSegmentSize
        fragments = fragments + 1
    end

    if self.logger then self.logger:debug("Data sent in %d fragments", fragments) end

    return true
end

function TCP:startKeepAlive()
    if self.keepAliveTimer then
        os.cancelTimer(self.keepAliveTimer)
    end

    if self.logger then self.logger:debug("Starting keep-alive timer: %s seconds", tostring(self.keepAlive)) end

    self.keepAliveTimer = os.startTimer(self.keepAlive)

    parallel.waitForAny(function()
        while self.connected do
            local event, timer = os.pullEvent("timer")
            if timer == self.keepAliveTimer then
                if self.logger then self.logger:trace("Sending keep-alive packet") end
                local packet = self:createPacket("ACK", nil)
                self:sendPacket(packet)
                self.keepAliveTimer = os.startTimer(self.keepAlive)
            end
        end
    end)
end

function TCP:startReceiveLoop()
    if self.logger then self.logger:debug("Starting receive loop") end

    parallel.waitForAny(
            function()
                while self.connected do
                    local packet, err = self:receivePacket(self.timeout)
                    if packet then
                        if packet.flags and packet.flags.FIN then
                            if self.logger then self.logger:info("Received FIN packet, closing connection") end
                            self:handleFIN(packet)
                            break
                        elseif packet.flags and packet.flags.ACK then
                            self:handleACK(packet)
                        elseif packet.data and #packet.data > 0 then
                            if self.logger then self.logger:trace("Received data packet: %d bytes", #packet.data) end
                            self:handleData(packet)
                        end
                    elseif err == "timeout" then
                        -- Ignore timeout errors in receive loop
                    else
                        if self.logger then self.logger:error("Error receiving packet: %s", err or "unknown error") end
                        self.callbacks.onError("Error receiving packet: " .. (err or "unknown error"))
                        break
                    end
                end
            end)
end

function TCP:receivePacket(timeout)
    local url = string.format("http://%s:%d/tcp/receive", self.host, self.port)
    local timer = os.startTimer(timeout)

    if self.logger then self.logger:trace("Waiting for packet from %s (timeout: %d)", url, timeout) end

    while true do
        local event, param1, param2 = os.pullEvent()
        if event == "http_success" then
            local reqUrl = param1.getURL()
            if reqUrl == url then
                local response = param1.readAll()
                param1.close()
                local packet = textutils.unserialiseJSON and textutils.unserialiseJSON(response) or textutils.unserialize(response)
                os.cancelTimer(timer)
                if self.logger then self.logger:trace("Packet received successfully") end
                return packet
            end
        elseif event == "http_failure" then
            local reqUrl = param1
            if reqUrl == url then
                os.cancelTimer(timer)
                if self.logger then self.logger:warn("HTTP failure when receiving packet") end
                return nil, "HTTP failure"
            end
        elseif event == "timer" and param1 == timer then
            return nil, "timeout"
        end
    end
end

function TCP:handleACK(packet)
    if packet.ackNumber and packet.ackNumber > self.sequenceNumber then
        if self.logger then
            self.logger:trace("ACK received, updating sequence number: %d -> %d",
                    self.sequenceNumber, packet.ackNumber)
        end
        self.sequenceNumber = packet.ackNumber
    end
end

function TCP:handleData(packet)
    table.insert(self.buffer, packet.data)
    self.ackNumber = packet.sequenceNumber + #packet.data

    if self.logger then
        self.logger:debug("Data received: %d bytes, Buffer size: %d", #packet.data, #self.buffer)
    end

    local ack = self:createPacket("ACK", nil)
    self:sendPacket(ack)

    self.callbacks.onData(packet.data)
end

function TCP:handleFIN(packet)
    self.ackNumber = packet.sequenceNumber + 1

    local ack = self:createPacket("ACK", nil)
    self:sendPacket(ack)

    self.status = STATUSES.TCP.CLOSE_WAIT
    self.connected = false

    if self.logger then
        self.logger:info("Connection closed by remote host")
        self.logger:debug("Status: CLOSE_WAIT")
    end

    self.callbacks.onClose()
end

function TCP:on(event, callback)
    if self.callbacks[event] then
        self.callbacks[event] = callback
        if self.logger then self.logger:debug("Callback set for event: %s", event) end
        return true
    else
        if self.logger then self.logger:warn("Invalid event name: %s", event) end
        return false, "Invalid event name"
    end
end

function TCP:close()
    if not self.connected then
        if self.logger then self.logger:warn("Cannot close: not connected") end
        return false, "Not connected"
    end

    if self.logger then self.logger:info("Closing TCP connection to %s:%d", self.host, self.port) end

    self.status = STATUSES.TCP.FIN_WAIT_1
    local fin = self:createPacket("FIN,ACK", nil)
    self:sendPacket(fin)

    sleep(0.01)
    local response, err = self:receivePacket(self.timeout)

    if not response then
        self.status = STATUSES.TCP.DISCONNECTED
        self.connected = false
        if self.logger then self.logger:error("Connection close timed out: %s", err or "unknown error") end
        return false, "Connection close timed out: " .. (err or "unknown error")
    end

    if response.flags and response.flags.ACK and response.ackNumber == self.sequenceNumber + 1 then
        self.status = STATUSES.TCP.TIME_WAIT
        self.connected = false
        self.callbacks.onClose()
        self.status = STATUSES.TCP.DISCONNECTED

        if self.logger then
            self.logger:info("TCP connection closed successfully")
            self.logger:debug("Status: DISCONNECTED")
        end

        return true, "Connection closed"
    else
        self.status = STATUSES.TCP.DISCONNECTED
        self.connected = false
        if self.logger then self.logger:error("Invalid response during close handshake") end
        return false, "Invalid response from server during close"
    end
end

function TCP:checkStatus()
    return self.status
end

function TCP:isConnected()
    return self.connected
end

function TCP:setTimeout(timeout)
    self.timeout = timeout
    if self.logger then self.logger:debug("Timeout set to: %d", timeout) end
end

function TCP:getTimeout()
    return self.timeout
end

function TCP:setKeepAlive(keepAlive)
    self.keepAlive = keepAlive
    if self.logger then self.logger:debug("Keep-alive set to: %s", tostring(keepAlive)) end

    if self.connected and keepAlive then
        self:startKeepAlive()
    elseif self.keepAliveTimer then
        os.cancelTimer(self.keepAliveTimer)
        self.keepAliveTimer = nil
    end
end

function TCP:getKeepAlive()
    return self.keepAlive
end

function TCP:setNoDelay(noDelay)
    self.noDelay = noDelay
    if self.logger then self.logger:debug("NoDelay set to: %s", tostring(noDelay)) end
end

function TCP:getNoDelay()
    return self.noDelay
end

function TCP:setBufferSize(size)
    self.bufferSize = size
    if self.logger then self.logger:debug("Buffer size set to: %d", size) end
end

function TCP:getBufferSize()
    return self.bufferSize
end

function TCP:setAddress(host, port)
    self.host = host
    self.port = port
    if self.logger then self.logger:info("Address changed to: %s:%d", host, port) end
end

function TCP:getAddress()
    return self.host, self.port
end

return TCP