-- protocols/ssh.lua
local PROTOCOL_NAMES = require("protocols.protocol_names") or error("Protocol Names Enum not available")
local STATUSES = require("protocols.statuses") or error("Statuses Enum not available")
local Logger = require("util.logger")

local c_http = http or _G.http or error("HTTP API not available")
local sleep = sleep or _G.sleep or os.sleep or function(t) os.sleep(t) end

local SSH = {}
SSH.__index = SSH
SSH.PROTOCOL_NAME = PROTOCOL_NAMES.ssh

SSH.SUPPORTED_METHODS = {
    "connect",
    "disconnect",
    "isConnected",
    "send",
    "receive",
    "setTimeout",
    "getTimeout",
    "authenticate",
    "passwordAuth",
    "publicKeyAuth",
    "executeCommand",
    "shell",
    "sftp",
    "openChannel",
    "closeChannel",
    "sendToChannel",
    "portForward",
}

-- Create a shared logger for all SSH instances
SSH.logger = Logger and Logger:new({
    title = "SSH Protocol",
    logFile = "logs/ssh.log",
    maxLogs = 500
}) or nil

function SSH:new(host, port, options)
    local obj = {}
    setmetatable(obj, self)
    obj.options = options or {}
    obj.host = host or obj.options.host or "localhost"
    obj.port = port or obj.options.port or 22
    obj.username = obj.options.username or "anonymous"
    obj.password = obj.options.password or "anonymous@"
    obj.timeout = obj.options.timeout or 5
    obj.connected = false
    obj.authenticated = false
    obj.sessionId = nil
    obj.channels = {}
    obj.nextChannelId = 1
    obj.callbacks = {
        onConnect = obj.options.onConnect or function() end,
        onDisconnect = obj.options.onDisconnect or function() end,
        onError = obj.options.onError or function(err) end,
        onData = obj.options.onData or function(data) end,
    }

    -- Use individual logger if provided, otherwise use shared
    obj.logger = obj.options.logger or SSH.logger

    if obj.logger then
        obj.logger:info("SSH instance created for %s:%d", host, port)
        obj.logger:debug("Default username: %s, Timeout: %d seconds", obj.username, obj.timeout)
    end

    return obj
end

function SSH:connect()
    if self.connected then
        if self.logger then
            self.logger:warn("SSH already connected to %s:%d", self.host, self.port)
        end
        return STATUSES.SSH.ALREADY_CONNECTED, "SSH is already connected!"
    end

    if self.logger then
        self.logger:info("Initiating SSH connection to %s:%d", self.host, self.port)
    end

    local url = string.format("http://%s:%d/ssh/connect", self.host, self.port)

    local payload = {
        clientVersion = "SSH-2.0-CCTweaked_1.0",
        supportedAlgorithms = {
            kex = {"diffie-hellman-group14-sha256"},
            hostKey = {"ssh-rsa"},
            encryption = {"aes128-ctr"},
            mac = {"hmac-sha2-256"},
            compression = {"none"}
        }
    }

    local serialized = textutils.serialiseJSON and textutils.serialiseJSON(payload) or textutils.serialize(payload)

    if self.logger then
        self.logger:debug("Sending SSH handshake with client version: %s", payload.clientVersion)
        self.logger:trace("Supported algorithms: kex=%s, encryption=%s",
                table.concat(payload.supportedAlgorithms.kex, ","),
                table.concat(payload.supportedAlgorithms.encryption, ","))
    end

    local success, response = pcall(function()
        return c_http.post(url, serialized, {["Content-Type"] = "application/json"})
    end)

    if success and response then
        local data = response.readAll()
        response.close()

        if data then
            local result = textutils.unserialiseJSON and textutils.unserialiseJSON(data) or textutils.unserialize(data)
            if result and result.sessionId then
                self.sessionId = result.sessionId
                self.connected = true

                if self.logger then
                    self.logger:info("SSH connection established - Session ID: %s", self.sessionId)
                end

                self.callbacks.onConnect()
                return true
            else
                if self.logger then
                    self.logger:error("Invalid response from SSH server - no session ID")
                end
            end
        end
    else
        if self.logger then
            self.logger:error("Failed to connect to SSH server: %s", tostring(response))
        end
    end

    return false, "Failed to establish SSH connection"
end

function SSH:authenticate(username, method, credentials)
    if not self.connected then
        if self.logger then
            self.logger:warn("Cannot authenticate: not connected")
        end
        return STATUSES.SSH.NOT_CONNECTED, "SSH is not connected!"
    end

    username = username or self.username
    method = method or "password"
    credentials = credentials or self.password

    if self.logger then
        self.logger:info("Authenticating as '%s' using method: %s", username, method)
    end

    local url = string.format("http://%s:%d/ssh/auth", self.host, self.port)

    local payload = {
        sessionId = self.sessionId,
        username = username,
        method = method,
        credentials = credentials
    }

    local serialized = textutils.serialiseJSON and textutils.serialiseJSON(payload) or textutils.serialize(payload)

    local success, response = pcall(function()
        return c_http.post(url, serialized, {["Content-Type"] = "application/json"})
    end)

    if success and response then
        local data = response.readAll()
        response.close()

        if data then
            local result = textutils.unserialiseJSON and textutils.unserialiseJSON(data) or textutils.unserialize(data)
            if result and result.authenticated then
                self.authenticated = true
                self.username = username

                if self.logger then
                    self.logger:info("Successfully authenticated as '%s'", username)
                end

                return true
            else
                if self.logger then
                    self.logger:error("Authentication failed for user '%s'", username)
                end
                return STATUSES.SSH.AUTH_FAILED, "Authentication failed!"
            end
        end
    else
        if self.logger then
            self.logger:error("Failed to send authentication request: %s", tostring(response))
        end
    end

    return false, "Authentication request failed"
end

function SSH:passwordAuth(username, password)
    if self.logger then
        self.logger:debug("Attempting password authentication for user: %s", username)
    end
    return self:authenticate(username, "password", {password = password})
end

function SSH:publicKeyAuth(username, privateKey)
    if self.logger then
        self.logger:debug("Attempting public key authentication for user: %s", username)
    end
    return self:authenticate(username, "publickey", {key = privateKey})
end

function SSH:openChannel(channelType, options)
    if not self.authenticated then
        if self.logger then
            self.logger:warn("Cannot open channel: not authenticated")
        end
        return STATUSES.SSH.NOT_AUTHENTICATED, "SSH is not authenticated!"
    end

    channelType = channelType or "session"
    options = options or {}

    local channelId = self.nextChannelId
    self.nextChannelId = self.nextChannelId + 1

    if self.logger then
        self.logger:info("Opening %s channel with ID: %d", channelType, channelId)
        if options.pty then
            self.logger:debug("PTY requested for channel")
        end
    end

    local url = string.format("http://%s:%d/ssh/channel/open", self.host, self.port)

    local payload = {
        sessionId = self.sessionId,
        channelId = channelId,
        channelType = channelType,
        options = options,
        windowSize = 32768,
        maxPacketSize = 16384
    }

    local serialized = textutils.serialiseJSON and textutils.serialiseJSON(payload) or textutils.serialize(payload)

    local success, response = pcall(function()
        return c_http.post(url, serialized, {["Content-Type"] = "application/json"})
    end)

    if success and response then
        local data = response.readAll()
        response.close()

        if data then
            local result = textutils.unserialiseJSON and textutils.unserialiseJSON(data) or textutils.unserialize(data)
            if result and result.success then
                self.channels[channelId] = {
                    type = channelType,
                    options = options,
                    windowSize = 32768,
                    maxPacketSize = 16384,
                    open = true
                }

                if self.logger then
                    self.logger:info("Channel %d opened successfully", channelId)
                end

                return channelId
            else
                if self.logger then
                    self.logger:error("Failed to open channel: server rejected")
                end
                return STATUSES.SSH.CHANNEL_OPEN_FAILED, "Failed to open channel!"
            end
        end
    else
        if self.logger then
            self.logger:error("Failed to send channel open request: %s", tostring(response))
        end
    end

    return STATUSES.SSH.CHANNEL_OPEN_FAILED, "Channel open request failed"
end

function SSH:executeCommand(command)
    if not self.authenticated then
        if self.logger then
            self.logger:warn("Cannot execute command: not authenticated")
        end
        return STATUSES.SSH.NOT_AUTHENTICATED, "SSH is not authenticated!"
    end

    if type(command) ~= "string" then
        if self.logger then
            self.logger:error("Invalid command type: %s", type(command))
        end
        return STATUSES.SSH.INVALID_COMMAND, "Command must be a string!"
    end

    if self.logger then
        self.logger:info("Executing command: %s", command)
    end

    local channelId, err = self:openChannel("session")
    if type(channelId) ~= "number" then
        if self.logger then
            self.logger:error("Failed to open channel for command execution: %s", tostring(err))
        end
        return err
    end

    local url = string.format("http://%s:%d/ssh/channel/exec", self.host, self.port)

    local payload = {
        sessionId = self.sessionId,
        channelId = channelId,
        command = command
    }

    local serialized = textutils.serialiseJSON and textutils.serialiseJSON(payload) or textutils.serialize(payload)

    local success, response = pcall(function()
        return c_http.post(url, serialized, {["Content-Type"] = "application/json"})
    end)

    if success and response then
        local data = response.readAll()
        response.close()

        if data then
            local result = textutils.unserialiseJSON and textutils.unserialiseJSON(data) or textutils.unserialize(data)
            if result and result.success then
                if self.logger then
                    self.logger:info("Command executed successfully")
                    if result.output then
                        self.logger:debug("Command output: %s", result.output)
                    end
                end

                -- Close the channel after execution
                self:closeChannel(channelId)

                return result.output or true
            else
                if self.logger then
                    self.logger:error("Command execution failed")
                end
                return STATUSES.SSH.COMMAND_EXEC_FAILED, "Failed to execute command!"
            end
        end
    else
        if self.logger then
            self.logger:error("Failed to send command execution request: %s", tostring(response))
        end
    end

    return STATUSES.SSH.COMMAND_EXEC_FAILED, "Command execution request failed"
end

function SSH:shell()
    if not self.authenticated then
        if self.logger then
            self.logger:warn("Cannot start shell: not authenticated")
        end
        return STATUSES.SSH.NOT_AUTHENTICATED, "SSH is not authenticated!"
    end

    if self.logger then
        self.logger:info("Starting interactive shell session")
    end

    local channelId, err = self:openChannel("session", {pty = true})
    if type(channelId) ~= "number" then
        if self.logger then
            self.logger:error("Failed to open channel for shell: %s", tostring(err))
        end
        return err
    end

    if self.logger then
        self.logger:info("Interactive shell started on channel %d", channelId)
    end

    while true do
        write(self.username .. "@" .. self.host .. ":~$ ")
        local input = read()

        if input == "exit" then
            if self.logger then
                self.logger:info("Exiting shell session")
            end
            break
        end

        local output = self:sendToChannel(channelId, input .. "\n")
        if output then
            print(output)
        end
    end

    self:closeChannel(channelId)
    return true
end

function SSH:sendToChannel(channelId, data)
    if not self.authenticated then
        if self.logger then
            self.logger:warn("Cannot send to channel: not authenticated")
        end
        return STATUSES.SSH.NOT_AUTHENTICATED, "SSH is not authenticated!"
    end

    if not self.channels[channelId] or not self.channels[channelId].open then
        if self.logger then
            self.logger:warn("Cannot send to channel %d: channel not open", channelId)
        end
        return STATUSES.SSH.CHANNEL_CLOSED, "Channel is not open!"
    end

    if type(data) ~= "string" then
        if self.logger then
            self.logger:error("Invalid data type for channel %d: %s", channelId, type(data))
        end
        return STATUSES.SSH.INVALID_DATA, "Data must be a string!"
    end

    if self.logger then
        self.logger:debug("Sending %d bytes to channel %d", #data, channelId)
        self.logger:trace("Data: %s", data)
    end

    local url = string.format("http://%s:%d/ssh/channel/send", self.host, self.port)

    local payload = {
        sessionId = self.sessionId,
        channelId = channelId,
        data = data
    }

    local serialized = textutils.serialiseJSON and textutils.serialiseJSON(payload) or textutils.serialize(payload)

    local success, response = pcall(function()
        return c_http.post(url, serialized, {["Content-Type"] = "application/json"})
    end)

    if success and response then
        local respData = response.readAll()
        response.close()

        if respData then
            local result = textutils.unserialiseJSON and textutils.unserialiseJSON(respData) or textutils.unserialize(respData)
            if result and result.data then
                if self.logger then
                    self.logger:trace("Received response from channel %d: %d bytes", channelId, #result.data)
                end
                return result.data
            else
                if self.logger then
                    self.logger:warn("Failed to send data to channel %d", channelId)
                end
                return STATUSES.SSH.SEND_FAILED, "Failed to send data!"
            end
        end
    else
        if self.logger then
            self.logger:error("Failed to send data to channel %d: %s", channelId, tostring(response))
        end
    end

    return STATUSES.SSH.SEND_FAILED, "Send request failed"
end

function SSH:closeChannel(channelId)
    if not self.authenticated then
        if self.logger then
            self.logger:warn("Cannot close channel: not authenticated")
        end
        return STATUSES.SSH.NOT_AUTHENTICATED, "SSH is not authenticated!"
    end

    if not self.channels[channelId] or not self.channels[channelId].open then
        if self.logger then
            self.logger:warn("Channel %d already closed or doesn't exist", channelId)
        end
        return STATUSES.SSH.CHANNEL_CLOSED, "Channel is not open!"
    end

    if self.logger then
        self.logger:info("Closing channel %d", channelId)
    end

    local url = string.format("http://%s:%d/ssh/channel/close", self.host, self.port)

    local payload = {
        sessionId = self.sessionId,
        channelId = channelId
    }

    local serialized = textutils.serialiseJSON and textutils.serialiseJSON(payload) or textutils.serialize(payload)

    local success, response = pcall(function()
        return c_http.post(url, serialized, {["Content-Type"] = "application/json"})
    end)

    if success and response then
        local data = response.readAll()
        response.close()

        if data then
            local result = textutils.unserialiseJSON and textutils.unserialiseJSON(data) or textutils.unserialize(data)
            if result and result.closed then
                self.channels[channelId].open = false

                if self.logger then
                    self.logger:info("Channel %d closed successfully", channelId)
                end

                return true
            else
                if self.logger then
                    self.logger:error("Failed to close channel %d", channelId)
                end
                return STATUSES.SSH.CHANNEL_CLOSE_FAILED, "Failed to close channel!"
            end
        end
    else
        if self.logger then
            self.logger:error("Failed to send close channel request: %s", tostring(response))
        end
    end

    return STATUSES.SSH.CHANNEL_CLOSE_FAILED, "Close channel request failed"
end

function SSH:sftp()
    if not self.authenticated then
        if self.logger then
            self.logger:warn("Cannot start SFTP: not authenticated")
        end
        return nil
    end

    if self.logger then
        self.logger:info("Starting SFTP subsystem")
    end

    local channelId = self:openChannel("sftp")
    if type(channelId) ~= "number" then
        if self.logger then
            self.logger:error("Failed to open SFTP channel")
        end
        return nil
    end

    local channel = self.channels[channelId]

    if self.logger then
        self.logger:info("SFTP subsystem started on channel %d", channelId)
    end

    -- Return SFTP operations object
    return {
        channelId = channelId,
        ssh = self,

        list = function(self, path)
            if self.ssh.logger then
                self.ssh.logger:debug("SFTP: Listing directory: %s", path or "/")
            end
            return self.ssh:sftpCommand(self.channelId, "list", {path = path or "/"})
        end,

        get = function(self, remotePath, localPath)
            if self.ssh.logger then
                self.ssh.logger:info("SFTP: Downloading %s to %s", remotePath, localPath)
            end

            local data = self.ssh:sftpCommand(self.channelId, "get", {path = remotePath})
            if data then
                local file = fs.open(localPath, "wb")
                if file then
                    file.write(data)
                    file.close()

                    if self.ssh.logger then
                        self.ssh.logger:info("SFTP: Successfully downloaded %s", remotePath)
                    end

                    return true
                else
                    if self.ssh.logger then
                        self.ssh.logger:error("SFTP: Failed to write local file %s", localPath)
                    end
                end
            else
                if self.ssh.logger then
                    self.ssh.logger:error("SFTP: Failed to download %s", remotePath)
                end
            end
            return false
        end,

        put = function(self, localPath, remotePath)
            if self.ssh.logger then
                self.ssh.logger:info("SFTP: Uploading %s to %s", localPath, remotePath)
            end

            if not fs.exists(localPath) then
                if self.ssh.logger then
                    self.ssh.logger:error("SFTP: Local file not found: %s", localPath)
                end
                return false
            end

            local file = fs.open(localPath, "rb")
            if not file then
                if self.ssh.logger then
                    self.ssh.logger:error("SFTP: Failed to read local file: %s", localPath)
                end
                return false
            end

            local content = file.readAll()
            file.close()

            local result = self.ssh:sftpCommand(self.channelId, "put", {
                path = remotePath,
                data = content
            })

            if result then
                if self.ssh.logger then
                    self.ssh.logger:info("SFTP: Successfully uploaded %s", localPath)
                end
            else
                if self.ssh.logger then
                    self.ssh.logger:error("SFTP: Failed to upload %s", localPath)
                end
            end

            return result
        end,

        mkdir = function(self, path)
            if self.ssh.logger then
                self.ssh.logger:debug("SFTP: Creating directory: %s", path)
            end
            return self.ssh:sftpCommand(self.channelId, "mkdir", {path = path})
        end,

        rmdir = function(self, path)
            if self.ssh.logger then
                self.ssh.logger:debug("SFTP: Removing directory: %s", path)
            end
            return self.ssh:sftpCommand(self.channelId, "rmdir", {path = path})
        end,

        delete = function(self, path)
            if self.ssh.logger then
                self.ssh.logger:debug("SFTP: Deleting file: %s", path)
            end
            return self.ssh:sftpCommand(self.channelId, "delete", {path = path})
        end,

        close = function(self)
            if self.ssh.logger then
                self.ssh.logger:info("SFTP: Closing subsystem")
            end
            self.ssh:closeChannel(self.channelId)
        end
    }
end

function SSH:sftpCommand(channelId, command, params)
    if not self.authenticated then
        if self.logger then
            self.logger:warn("Cannot execute SFTP command: not authenticated")
        end
        return STATUSES.SSH.NOT_AUTHENTICATED, "SSH is not authenticated!"
    end

    if not self.channels[channelId] or not self.channels[channelId].open then
        if self.logger then
            self.logger:warn("Cannot execute SFTP command: channel %d not open", channelId)
        end
        return STATUSES.SSH.CHANNEL_CLOSED, "Channel is not open!"
    end

    if self.logger then
        self.logger:trace("SFTP command '%s' on channel %d", command, channelId)
    end

    local url = string.format("http://%s:%d/ssh/channel/sftp", self.host, self.port)

    local payload = {
        sessionId = self.sessionId,
        channelId = channelId,
        command = command,
        params = params
    }

    local serialized = textutils.serialiseJSON and textutils.serialiseJSON(payload) or textutils.serialize(payload)

    local success, response = pcall(function()
        return c_http.post(url, serialized, {["Content-Type"] = "application/json"})
    end)

    if success and response then
        local respData = response.readAll()
        response.close()

        if respData then
            local result = textutils.unserialiseJSON and textutils.unserialiseJSON(respData) or textutils.unserialize(respData)
            if result and result.success then
                return result.data
            else
                if self.logger then
                    self.logger:error("SFTP command '%s' failed", command)
                end
                return STATUSES.SSH.SFTP_COMMAND_FAILED, "SFTP command failed!"
            end
        end
    else
        if self.logger then
            self.logger:error("Failed to send SFTP command: %s", tostring(response))
        end
    end

    return STATUSES.SSH.SFTP_COMMAND_FAILED, "SFTP command request failed"
end

function SSH:portForward(localPort, remoteHost, remotePort)
    if not self.authenticated then
        if self.logger then
            self.logger:warn("Cannot setup port forwarding: not authenticated")
        end
        return false
    end

    if self.logger then
        self.logger:info("Setting up port forwarding: localhost:%d -> %s:%d",
                localPort, remoteHost, remotePort)
    end

    local channelId = self:openChannel("direct-tcpip")
    if type(channelId) ~= "number" then
        if self.logger then
            self.logger:error("Failed to open channel for port forwarding")
        end
        return false
    end

    local url = string.format("http://%s:%d/ssh/forward", self.host, self.port)

    local payload = {
        sessionId = self.sessionId,
        channelId = channelId,
        localPort = localPort,
        remoteHost = remoteHost,
        remotePort = remotePort
    }

    local serialized = textutils.serialiseJSON and textutils.serialiseJSON(payload) or textutils.serialize(payload)

    local success, response = pcall(function()
        return c_http.post(url, serialized, {["Content-Type"] = "application/json"})
    end)

    if success and response then
        response.close()

        if self.logger then
            self.logger:info("Port forwarding established successfully")
        end

        print(string.format("Port forwarding: localhost:%d -> %s:%d",
                localPort, remoteHost, remotePort))

        return true
    else
        if self.logger then
            self.logger:error("Failed to establish port forwarding: %s", tostring(response))
        end
    end

    return false
end

function SSH:on(event, callback)
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
        return false
    end
end

function SSH:send(message)
    -- For compatibility - execute as command
    if self.logger then
        self.logger:debug("Send called - executing as command")
    end
    return self:executeCommand(message)
end

function SSH:isConnected()
    return self.connected
end

function SSH:checkStatus()
    if self.connected and self.authenticated then
        return STATUSES.ssh_authenticated
    elseif self.connected then
        return STATUSES.connected
    else
        return STATUSES.disconnected
    end
end

function SSH:disconnect()
    if not self.connected then
        if self.logger then
            self.logger:warn("Already disconnected")
        end
        return STATUSES.SSH.NOT_CONNECTED, "SSH is not connected!"
    end

    if self.logger then
        self.logger:info("Disconnecting SSH session")
    end

    -- Close all open channels first
    for channelId, channel in pairs(self.channels) do
        if channel.open then
            if self.logger then
                self.logger:debug("Closing channel %d before disconnect", channelId)
            end
            self:closeChannel(channelId)
        end
    end

    local url = string.format("http://%s:%d/ssh/disconnect", self.host, self.port)

    local payload = {
        sessionId = self.sessionId
    }

    local serialized = textutils.serialiseJSON and textutils.serialiseJSON(payload) or textutils.serialize(payload)

    local success, response = pcall(function()
        return c_http.post(url, serialized, {["Content-Type"] = "application/json"})
    end)

    if success and response then
        local data = response.readAll()
        response.close()

        if data then
            local result = textutils.unserialiseJSON and textutils.unserialiseJSON(data) or textutils.unserialize(data)
            if result and result.disconnected then
                self.connected = false
                self.authenticated = false
                self.sessionId = nil
                self.channels = {}
                self.nextChannelId = 1

                if self.logger then
                    self.logger:info("SSH session disconnected successfully")
                end

                self.callbacks.onDisconnect()
                return true
            else
                if self.logger then
                    self.logger:error("Failed to disconnect cleanly")
                end
                return STATUSES.SSH.DISCONNECT_FAILED, "Failed to disconnect!"
            end
        end
    else
        if self.logger then
            self.logger:error("Failed to send disconnect request: %s", tostring(response))
        end
    end

    -- Force disconnect even if request failed
    self.connected = false
    self.authenticated = false
    self.sessionId = nil
    self.channels = {}
    self.nextChannelId = 1
    self.callbacks.onDisconnect()

    return false, "Forced disconnect"
end

-- Alias for disconnect
function SSH:close()
    return self:disconnect()
end

function SSH:setTimeout(timeout)
    self.timeout = timeout
    if self.logger then
        self.logger:debug("Timeout set to: %d seconds", timeout)
    end
end

function SSH:getTimeout()
    return self.timeout
end

return SSH