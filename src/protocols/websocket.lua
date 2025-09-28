-- protocols/websocket.lua
local PROTOCOL_NAMES = require("protocols.protocol_names") or error("Protocol Names Enum not available")
local STATUSES = require("protocols.statuses") or error("Statuses Enum not available")
local Logger = require("util.logger")
local NetworkAdapter = require("protocols.network_adapter")

local parallel = parallel or _G.parallel or error("parallel API not found")
local os_startTimer = os.startTimer or function(t) return os.startTimer and os.startTimer(t) or error("os.startTimer not available") end
local os_pullEvent = os.pullEvent or function(...) return os.pullEvent and os.pullEvent(...) or error("os.pullEvent not available") end
local sleep = sleep or _G.sleep or os.sleep or function(t) os.sleep(t) end

local WebSocket = {}
WebSocket.__index = WebSocket
WebSocket.PROTOCOL_NAME = PROTOCOL_NAMES.websocket
WebSocket.SUPPORTED_METHODS = {
    "connect",
    "send",
    "receive",
    "close",
    "isOpen",
    "setCallback",
    "poll",
}

-- Create a shared logger for all WebSocket instances
WebSocket.logger = Logger and Logger:new({
    title = "WebSocket Protocol",
    logFile = "logs/websocket.log",
    maxLogs = 500
}) or nil

function WebSocket:new(address, options)
    local obj = {}
    setmetatable(obj, self)

    obj.address = address
    obj.options = options or {}
    obj.connected = false
    obj.messageQueue = {}
    obj.callbacks = {}
    obj.pollInterval = obj.options.pollInterval or 1
    obj.lastPollTime = 0
    obj.ws = nil
    obj.receiveTimeout = obj.options.receiveTimeout or 5

    -- Network configuration
    obj.networkType = obj.options.networkType or NetworkAdapter.NETWORK_TYPES.AUTO
    obj.networkAdapter = NetworkAdapter:new(obj.networkType, {
        logger = obj.options.logger
    })

    -- Use individual logger if provided, otherwise use shared
    obj.logger = obj.options.logger or WebSocket.logger

    -- Initialize callbacks
    obj.callbacks = {
        onOpen = obj.options.onOpen or function() end,
        onClose = obj.options.onClose or function() end,
        onError = obj.options.onError or function(err) end,
        onMessage = obj.options.onMessage or function(msg) end,
    }

    if obj.logger then
        obj.logger:info("WebSocket instance created for: %s", address)
        obj.logger:debug("Network type: %s, pollInterval=%d, receiveTimeout=%d",
                obj.networkType, obj.pollInterval, obj.receiveTimeout)
    end

    return obj
end

function WebSocket:connect()
    if self.connected then
        if self.logger then self.logger:warn("WebSocket already connected to: %s", self.address) end
        return STATUSES.WEBSOCKET.ALREADY_CONNECTED, "WebSocket is already connected!"
    end

    if self.logger then
        self.logger:info("Connecting to WebSocket: %s", self.address)
    end

    -- Use NetworkAdapter to establish connection
    local success, result = pcall(function()
        return self.networkAdapter:websocket(self.address)
    end)

    if success and result then
        self.ws = result
        self.connected = true

        if self.logger then
            local netType = self.networkAdapter:isLocalURL(self.address) and "local" or "remote"
            self.logger:info("Successfully connected to WebSocket: %s (%s network)", self.address, netType)
        end

        self.callbacks.onOpen()

        -- Start receive loop
        self:startReceiveLoop()

        return STATUSES.WEBSOCKET.OK, self
    else
        local err = result or "Unknown error"
        if self.logger then
            self.logger:error("Failed to connect to WebSocket %s: %s", self.address, err)
        end
        self.callbacks.onError(err)
        return STATUSES.WEBSOCKET.CONNECTION_FAILED, err
    end
end

function WebSocket:startReceiveLoop()
    if not self.ws then return end

    if self.logger then
        self.logger:debug("Starting receive loop for WebSocket")
    end

    parallel.waitForAny(function()
        while self.connected and self.ws do
            local success, message = pcall(function()
                return self.ws.receive and self.ws:receive(self.receiveTimeout) or self.ws.receive(self.receiveTimeout)
            end)

            if success and message then
                if self.logger then
                    self.logger:trace("Received message: %s", tostring(message))
                end
                table.insert(self.messageQueue, message)
                if self.callbacks.onMessage then
                    self.callbacks.onMessage(message)
                end
            elseif not success then
                -- Connection closed or error
                if self.logger then
                    self.logger:warn("WebSocket connection closed or errored")
                end
                self.connected = false
                if self.callbacks.onClose then
                    self.callbacks.onClose()
                end
                break
            end
        end
    end)
end

function WebSocket:send(message)
    if not self.connected then
        table.insert(self.messageQueue, message)
        if self.logger then
            self.logger:warn("Not connected, message queued: %s", tostring(message))
        end
        return STATUSES.WEBSOCKET.NOT_CONNECTED, "WebSocket is not connected! Message stored in queue."
    end

    if self.logger then
        self.logger:trace("Sending message: %s", tostring(message))
    end

    local success, err = pcall(function()
        return self.ws.send and self.ws:send(message) or self.ws.send(message)
    end)

    if success then
        if self.logger then
            self.logger:trace("Message sent successfully")
        end
        return STATUSES.WEBSOCKET.OK
    else
        if self.logger then
            self.logger:error("Failed to send message: %s", tostring(err))
        end
        return STATUSES.WEBSOCKET.SEND_FAILED, "Failed to send message: " .. tostring(err)
    end
end

function WebSocket:receive(timeout)
    timeout = timeout or self.receiveTimeout

    if self.logger then
        self.logger:trace("Attempting to receive message with timeout: %d", timeout)
    end

    -- Check message queue first
    if #self.messageQueue > 0 then
        local msg = table.remove(self.messageQueue, 1)
        if self.logger then
            self.logger:trace("Retrieved message from queue: %s", tostring(msg))
        end
        return msg
    end

    -- Try to receive directly
    if self.ws then
        local success, message = pcall(function()
            return self.ws.receive and self.ws:receive(timeout) or self.ws.receive(timeout)
        end)

        if success then
            if self.logger then
                self.logger:trace("Received message: %s", tostring(message))
            end
            return message
        else
            if self.logger then
                self.logger:warn("Receive failed: %s", tostring(message))
            end
            return nil, "Receive failed: " .. tostring(message)
        end
    else
        -- Wait for message with timeout
        local timer = os_startTimer(timeout)
        while true do
            local event, param1 = os_pullEvent()
            if event == "timer" and param1 == timer then
                if self.logger then
                    self.logger:trace("Receive timeout reached")
                end
                return nil, "Timeout"
            elseif #self.messageQueue > 0 then
                local msg = table.remove(self.messageQueue, 1)
                os.cancelTimer(timer)
                if self.logger then
                    self.logger:trace("Retrieved message from queue: %s", tostring(msg))
                end
                return msg
            end
        end
    end
end

function WebSocket:on(event, callback)
    if self.logger then
        self.logger:debug("Setting callback for event: %s", event)
    end

    if event == "message" then
        self.callbacks.onMessage = callback
    elseif event == "open" then
        self.callbacks.onOpen = callback
    elseif event == "close" then
        self.callbacks.onClose = callback
    elseif event == "error" then
        self.callbacks.onError = callback
    else
        self.callbacks[event] = callback
    end
end

function WebSocket:isOpen()
    return self.connected
end

function WebSocket:checkStatus()
    local status = self.connected and STATUSES.websocket_open or STATUSES.websocket_closed

    if self.logger then
        self.logger:trace("Status check: %s", status)
    end
    return status
end

function WebSocket:close()
    if not self.connected then
        if self.logger then
            self.logger:warn("WebSocket already closed")
        end
        return STATUSES.WEBSOCKET.NOT_CONNECTED, "WebSocket is not connected!"
    end

    if self.logger then
        self.logger:info("Closing WebSocket connection to: %s", self.address)
    end

    self.connected = false

    if self.ws then
        local success, err = pcall(function()
            if self.ws.close then
                self.ws:close()
            else
                self.ws.close()
            end
        end)

        if not success then
            if self.logger then
                self.logger:error("Error closing WebSocket: %s", tostring(err))
            end
            return STATUSES.WEBSOCKET.CALLBACK_ERROR, tostring(err)
        end
    end

    if self.callbacks.onClose then
        local success, err = pcall(self.callbacks.onClose)
        if not success then
            if self.logger then
                self.logger:error("Error in onClose callback: %s", tostring(err))
            end
            return STATUSES.WEBSOCKET.CALLBACK_ERROR, tostring(err)
        end
    end

    if self.logger then
        self.logger:info("WebSocket closed successfully")
    end
    return STATUSES.WEBSOCKET.CLOSED
end

return WebSocket