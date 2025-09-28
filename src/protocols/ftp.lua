-- protocols/ftp.lua
local PROTOCOL_NAMES = require("protocols.protocol_names") or error("Protocol Names Enum not available")
local STATUSES = require("protocols.statuses") or error("Statuses Enum not available")
local Logger = require("util.logger")

local c_http = http or _G.http or error("HTTP API not available")
local sleep = sleep or _G.sleep or os.sleep or function(t) os.sleep(t) end

local FTP = {}
FTP.__index = FTP
FTP.PROTOCOL_NAME = PROTOCOL_NAMES.ftp

FTP.SUPPORTED_METHODS = {
    "connect",
    "disconnect",
    "login",
    "list",
    "get",
    "put",
    "delete",
    "rename",
    "makeDirectory",
    "removeDirectory",
    "changeDirectory",
    "getCurrentDirectory",
    "upload",
    "download",
    "setMode",
    "setPassive",
}

-- Create a shared logger for all FTP instances
FTP.logger = Logger and Logger:new({
    title = "FTP Protocol",
    logFile = "logs/ftp.log",
    maxLogs = 500
}) or nil

function FTP:new(address, options)
    local obj = {}
    setmetatable(obj, self)

    obj.options = options or {}
    obj.connected = false
    obj.ftp = nil
    obj.username = obj.options.username or "anonymous"
    obj.password = obj.options.password or "anonymous@"
    obj.host = obj.options.host or address
    obj.port = obj.options.port or 21
    obj.timeout = obj.options.timeout or 10
    obj.passive = obj.options.passive ~= false  -- Default to passive mode
    obj.mode = obj.options.mode or "binary" -- or "ascii"
    obj.authenticated = false
    obj.currentDirectory = "/"
    obj.callbacks = {
        onConnect = obj.options.onConnect or function() end,
        onDisconnect = obj.options.onDisconnect or function() end,
        onError = obj.options.onError or function() end,
        onTransferStart = obj.options.onTransferStart or function() end,
        onTransferComplete = obj.options.onTransferComplete or function() end,
    }

    -- Use individual logger if provided, otherwise use shared
    obj.logger = obj.options.logger or FTP.logger

    if obj.mode ~= "binary" and obj.mode ~= "ascii" then
        local err = "Invalid mode. Use 'binary' or 'ascii'."
        if obj.logger then
            obj.logger:error(err)
        end
        return nil, STATUSES.FTP.INVALID_MODE, err
    end

    if obj.logger then
        obj.logger:info("FTP client created for %s:%d", obj.host, obj.port)
        obj.logger:debug("Mode: %s, Passive: %s, Timeout: %d seconds",
                obj.mode, tostring(obj.passive), obj.timeout)
    end

    return obj
end

function FTP:connect()
    if self.connected then
        if self.logger then
            self.logger:warn("Already connected to FTP server %s:%d", self.host, self.port)
        end
        return STATUSES.FTP.ALREADY_CONNECTED, "FTP is already connected!"
    end

    if self.logger then
        self.logger:info("Connecting to FTP server %s:%d", self.host, self.port)
    end

    local url = string.format("http://%s:%d/ftp/connect", self.host, self.port)

    local success, response = pcall(function()
        return c_http.post(url, "")
    end)

    if success and response then
        local code = response.getResponseCode and response.getResponseCode() or 0
        local data = response.readAll()
        response.close()

        if code == 200 then
            self.connected = true

            if self.logger then
                self.logger:info("Successfully connected to FTP server")
                if data then
                    self.logger:debug("Server response: %s", data)
                end
            end

            self.callbacks.onConnect()
            return STATUSES.FTP.SUCCESS, "Connected to FTP server."
        else
            if self.logger then
                self.logger:error("Failed to connect - Server returned code: %d", code)
            end
        end
    else
        if self.logger then
            self.logger:error("Failed to connect to FTP server: %s", tostring(response))
        end
    end

    return STATUSES.FTP.CONNECTION_FAILED, "Failed to connect to FTP server."
end

function FTP:login(username, password)
    if not self.connected then
        if self.logger then
            self.logger:warn("Cannot login: not connected")
        end
        return false
    end

    username = username or self.username
    password = password or self.password

    if self.logger then
        self.logger:info("Logging in as user: %s", username)
    end

    local cmd = self:sendCommand("USER", username)
    if cmd.code ~= 331 then
        if self.logger then
            self.logger:error("USER command failed with code: %d", cmd.code)
        end
        return false
    end

    cmd = self:sendCommand("PASS", password)
    if cmd.code == 230 then
        self.authenticated = true
        self.username = username

        if self.logger then
            self.logger:info("Successfully authenticated as %s", username)
        end

        -- Set transfer mode
        self:setMode(self.mode)

        -- Set passive mode if configured
        if self.passive then
            self:setPassive(true)
        end

        return true
    else
        if self.logger then
            self.logger:error("PASS command failed with code: %d", cmd.code)
        end
    end

    return false
end

function FTP:sendCommand(command, argument)
    if not self.connected then
        if self.logger then
            self.logger:warn("Cannot send command: not connected")
        end
        return {code = 0, message = "Not connected"}
    end

    local fullCommand = command
    if argument then
        fullCommand = fullCommand .. " " .. argument
    end

    if self.logger then
        if command == "PASS" then
            self.logger:trace("Sending command: PASS ****")
        else
            self.logger:trace("Sending command: %s", fullCommand)
        end
    end

    local url = string.format("http://%s:%d/ftp/command", self.host, self.port)
    local body = textutils.serialiseJSON and
            textutils.serialiseJSON({command = command, argument = argument}) or
            textutils.serialize({command = command, argument = argument})

    local success, response = pcall(function()
        return c_http.post(url, body)
    end)

    if success and response then
        local code = response.getResponseCode and response.getResponseCode() or 0
        local message = response.readAll()
        response.close()

        if self.logger then
            self.logger:trace("Command response - Code: %d, Message: %s", code, message or "")
        end

        return {code = code, message = message}
    else
        if self.logger then
            self.logger:error("Failed to send command: %s", tostring(response))
        end
        return {code = 0, message = "No response"}
    end
end

function FTP:setMode(mode)
    if mode ~= "binary" and mode ~= "ascii" then
        if self.logger then
            self.logger:error("Invalid transfer mode: %s", mode)
        end
        return false
    end

    if self.logger then
        self.logger:debug("Setting transfer mode to: %s", mode)
    end

    local typeCmd = mode == "binary" and "I" or "A"
    local cmd = self:sendCommand("TYPE", typeCmd)

    if cmd.code == 200 then
        self.mode = mode
        if self.logger then
            self.logger:info("Transfer mode set to: %s", mode)
        end
        return true
    else
        if self.logger then
            self.logger:error("Failed to set transfer mode - Code: %d", cmd.code)
        end
        return false
    end
end

function FTP:setPassive(enabled)
    self.passive = enabled

    if self.logger then
        self.logger:debug("Passive mode %s", enabled and "enabled" or "disabled")
    end

    if enabled and self.connected then
        local cmd = self:sendCommand("PASV")
        if cmd.code == 227 then
            if self.logger then
                self.logger:info("Entered passive mode")
            end
            return true
        else
            if self.logger then
                self.logger:warn("Failed to enter passive mode - Code: %d", cmd.code)
            end
            return false
        end
    end

    return true
end

function FTP:list(path)
    if not self.connected or not self.authenticated then
        if self.logger then
            self.logger:warn("Cannot list directory: %s",
                    not self.connected and "not connected" or "not authenticated")
        end
        return nil, STATUSES.FTP.NOT_AUTHENTICATED, "Not authenticated."
    end

    path = path or self.currentDirectory

    if self.logger then
        self.logger:info("Listing directory: %s", path)
    end

    if self.passive then
        self:sendCommand("PASV")
    end

    local cmd = self:sendCommand("LIST", path)
    if cmd.code == 150 or cmd.code == 125 then
        if self.logger then
            self.logger:debug("Data connection opened for directory listing")
        end

        local url = string.format("http://%s:%d/ftp/data", self.host, self.port)

        local success, response = pcall(function()
            return c_http.get(url)
        end)

        if success and response then
            local listing = response.readAll()
            response.close()

            if self.logger then
                self.logger:debug("Directory listing received: %d bytes", #listing)
            end

            local files = self:parseList(listing)

            if self.logger then
                self.logger:info("Directory contains %d items", #files)
            end

            return files
        else
            if self.logger then
                self.logger:error("Failed to retrieve directory listing: %s", tostring(response))
            end
        end
    else
        if self.logger then
            self.logger:error("LIST command failed - Code: %d", cmd.code)
        end
    end

    return nil, STATUSES.FTP.LIST_FAILED, "Failed to list directory."
end

function FTP:parseList(listing)
    local files = {}

    for line in listing:gmatch("[^\r\n]+") do
        local parts = {}
        for part in line:gmatch("%S+") do
            table.insert(parts, part)
        end

        if #parts >= 9 then
            local file = {
                permissions = parts[1],
                links = tonumber(parts[2]),
                owner = parts[3],
                group = parts[4],
                size = tonumber(parts[5]),
                month = parts[6],
                day = parts[7],
                timeOrYear = parts[8],
                name = table.concat(parts, " ", 9),
                isDirectory = parts[1]:sub(1, 1) == "d"
            }
            table.insert(files, file)

            if self.logger then
                self.logger:trace("Parsed file: %s %s (%d bytes)",
                        file.isDirectory and "[DIR]" or "[FILE]",
                        file.name, file.size)
            end
        end
    end

    return files
end

function FTP:changeDirectory(directory)
    if not self.connected or not self.authenticated then
        if self.logger then
            self.logger:warn("Cannot change directory: %s",
                    not self.connected and "not connected" or "not authenticated")
        end
        return STATUSES.FTP.NOT_AUTHENTICATED, "Not authenticated."
    end

    if self.logger then
        self.logger:info("Changing directory to: %s", directory)
    end

    local cmd = self:sendCommand("CWD", directory)
    if cmd.code == 250 then
        self.currentDirectory = directory

        if self.logger then
            self.logger:info("Changed to directory: %s", directory)
        end

        return STATUSES.FTP.SUCCESS, "Changed directory."
    else
        if self.logger then
            self.logger:error("Failed to change directory - Code: %d", cmd.code)
        end
    end

    return STATUSES.FTP.CHANGE_DIR_FAILED, "Failed to change directory."
end

function FTP:getCurrentDirectory()
    if not self.connected or not self.authenticated then
        if self.logger then
            self.logger:warn("Cannot get current directory: %s",
                    not self.connected and "not connected" or "not authenticated")
        end
        return nil, STATUSES.FTP.NOT_AUTHENTICATED, "Not authenticated."
    end

    if self.logger then
        self.logger:debug("Getting current directory")
    end

    local cmd = self:sendCommand("PWD")
    if cmd.code == 257 then
        local dir = cmd.message:match('%"(.-)%"')
        if dir then
            self.currentDirectory = dir

            if self.logger then
                self.logger:info("Current directory: %s", dir)
            end

            return dir, STATUSES.FTP.SUCCESS, "Current directory retrieved."
        end
    else
        if self.logger then
            self.logger:error("PWD command failed - Code: %d", cmd.code)
        end
    end

    return nil, STATUSES.FTP.PWD_FAILED, "Failed to get current directory."
end

function FTP:upload(localFile, remoteName)
    if not self.connected or not self.authenticated then
        if self.logger then
            self.logger:warn("Cannot upload: %s",
                    not self.connected and "not connected" or "not authenticated")
        end
        return STATUSES.FTP.NOT_AUTHENTICATED, "Not authenticated."
    end

    remoteName = remoteName or fs.getName(localFile)

    if self.logger then
        self.logger:info("Uploading %s as %s", localFile, remoteName)
    end

    if not fs.exists(localFile) or fs.isDir(localFile) then
        if self.logger then
            self.logger:error("Local file not found or is directory: %s", localFile)
        end
        return STATUSES.FTP.LOCAL_FILE_NOT_FOUND, "Local file not found or is a directory."
    end

    local file = fs.open(localFile, "rb")
    if not file then
        if self.logger then
            self.logger:error("Failed to open local file: %s", localFile)
        end
        return STATUSES.FTP.FILE_OPEN_FAILED, "Failed to open local file."
    end

    local content = file.readAll()
    file.close()

    local fileSize = #content

    if self.logger then
        self.logger:debug("File size: %d bytes", fileSize)
    end

    if self.passive then
        self:sendCommand("PASV")
    end

    self.callbacks.onTransferStart(remoteName, fileSize)

    local cmd = self:sendCommand("STOR", remoteName)

    if cmd.code == 150 or cmd.code == 125 then
        if self.logger then
            self.logger:debug("Data connection opened for upload")
        end

        local url = string.format("http://%s:%d/ftp/data", self.host, self.port)

        local success, response = pcall(function()
            return c_http.post(url, content)
        end)

        if success and response then
            local respCode = response.getResponseCode and response.getResponseCode() or 0
            response.close()

            if respCode == 226 then
                if self.logger then
                    self.logger:info("Successfully uploaded %s (%d bytes)", remoteName, fileSize)
                end

                self.callbacks.onTransferComplete(remoteName, fileSize, true)
                return STATUSES.FTP.SUCCESS, "File uploaded successfully."
            else
                if self.logger then
                    self.logger:error("Upload failed - Response code: %d", respCode)
                end
            end
        else
            if self.logger then
                self.logger:error("Failed to send file data: %s", tostring(response))
            end
        end
    else
        if self.logger then
            self.logger:error("STOR command failed - Code: %d", cmd.code)
        end
    end

    self.callbacks.onTransferComplete(remoteName, fileSize, false)
    return STATUSES.FTP.UPLOAD_FAILED, "Failed to upload file."
end

function FTP:download(remoteFile, localName)
    if not self.connected or not self.authenticated then
        if self.logger then
            self.logger:warn("Cannot download: %s",
                    not self.connected and "not connected" or "not authenticated")
        end
        return STATUSES.FTP.NOT_AUTHENTICATED, "Not authenticated."
    end

    localName = localName or fs.getName(remoteFile)

    if self.logger then
        self.logger:info("Downloading %s as %s", remoteFile, localName)
    end

    if self.passive then
        self:sendCommand("PASV")
    end

    -- Get file size if possible
    local sizeCmd = self:sendCommand("SIZE", remoteFile)
    local fileSize = 0
    if sizeCmd.code == 213 then
        fileSize = tonumber(sizeCmd.message) or 0
        if self.logger then
            self.logger:debug("Remote file size: %d bytes", fileSize)
        end
    end

    self.callbacks.onTransferStart(remoteFile, fileSize)

    local cmd = self:sendCommand("RETR", remoteFile)
    if cmd.code == 150 or cmd.code == 125 then
        if self.logger then
            self.logger:debug("Data connection opened for download")
        end

        local url = string.format("http://%s:%d/ftp/data", self.host, self.port)

        local success, response = pcall(function()
            return c_http.get(url)
        end)

        if success and response then
            local content = response.readAll()
            response.close()

            if self.logger then
                self.logger:debug("Downloaded %d bytes", #content)
            end

            local file = fs.open(localName, "wb")
            if file then
                file.write(content)
                file.close()

                if self.logger then
                    self.logger:info("Successfully downloaded %s (%d bytes)", localName, #content)
                end

                self.callbacks.onTransferComplete(remoteFile, #content, true)
                return STATUSES.FTP.SUCCESS, "File downloaded successfully."
            else
                if self.logger then
                    self.logger:error("Failed to write local file: %s", localName)
                end
                self.callbacks.onTransferComplete(remoteFile, #content, false)
                return STATUSES.FTP.FILE_OPEN_FAILED, "Failed to open local file for writing."
            end
        else
            if self.logger then
                self.logger:error("Failed to retrieve file data: %s", tostring(response))
            end
        end
    else
        if self.logger then
            self.logger:error("RETR command failed - Code: %d", cmd.code)
        end
    end

    self.callbacks.onTransferComplete(remoteFile, 0, false)
    return STATUSES.FTP.DOWNLOAD_FAILED, "Failed to download file."
end

-- Alias for download
function FTP:get(remoteFile, localName)
    return self:download(remoteFile, localName)
end

-- Alias for upload
function FTP:put(localFile, remoteName)
    return self:upload(localFile, remoteName)
end

function FTP:delete(remoteFile)
    if not self.connected or not self.authenticated then
        if self.logger then
            self.logger:warn("Cannot delete: %s",
                    not self.connected and "not connected" or "not authenticated")
        end
        return STATUSES.FTP.NOT_AUTHENTICATED, "Not authenticated."
    end

    if self.logger then
        self.logger:info("Deleting file: %s", remoteFile)
    end

    local cmd = self:sendCommand("DELE", remoteFile)
    if cmd.code == 250 then
        if self.logger then
            self.logger:info("Successfully deleted: %s", remoteFile)
        end
        return STATUSES.FTP.SUCCESS, "File deleted successfully."
    else
        if self.logger then
            self.logger:error("Failed to delete file - Code: %d", cmd.code)
        end
    end

    return STATUSES.FTP.DELETE_FAILED, "Failed to delete file."
end

function FTP:rename(oldName, newName)
    if not self.connected or not self.authenticated then
        if self.logger then
            self.logger:warn("Cannot rename: %s",
                    not self.connected and "not connected" or "not authenticated")
        end
        return STATUSES.FTP.NOT_AUTHENTICATED, "Not authenticated."
    end

    if self.logger then
        self.logger:info("Renaming %s to %s", oldName, newName)
    end

    local cmd = self:sendCommand("RNFR", oldName)
    if cmd.code == 350 then
        cmd = self:sendCommand("RNTO", newName)
        if cmd.code == 250 then
            if self.logger then
                self.logger:info("Successfully renamed %s to %s", oldName, newName)
            end
            return STATUSES.FTP.SUCCESS, "File renamed successfully."
        else
            if self.logger then
                self.logger:error("RNTO command failed - Code: %d", cmd.code)
            end
        end
    else
        if self.logger then
            self.logger:error("RNFR command failed - Code: %d", cmd.code)
        end
    end

    return STATUSES.FTP.DELETE_FAILED, "Failed to rename file."
end

function FTP:makeDirectory(directory)
    if not self.connected or not self.authenticated then
        if self.logger then
            self.logger:warn("Cannot create directory: %s",
                    not self.connected and "not connected" or "not authenticated")
        end
        return STATUSES.FTP.NOT_AUTHENTICATED, "Not authenticated."
    end

    if self.logger then
        self.logger:info("Creating directory: %s", directory)
    end

    local cmd = self:sendCommand("MKD", directory)
    if cmd.code == 257 then
        if self.logger then
            self.logger:info("Successfully created directory: %s", directory)
        end
        return STATUSES.FTP.SUCCESS, "Directory created successfully."
    else
        if self.logger then
            self.logger:error("Failed to create directory - Code: %d", cmd.code)
        end
    end

    return STATUSES.FTP.MKDIR_FAILED, "Failed to create directory."
end

function FTP:removeDirectory(directory)
    if not self.connected or not self.authenticated then
        if self.logger then
            self.logger:warn("Cannot remove directory: %s",
                    not self.connected and "not connected" or "not authenticated")
        end
        return STATUSES.FTP.NOT_AUTHENTICATED, "Not authenticated."
    end

    if self.logger then
        self.logger:info("Removing directory: %s", directory)
    end

    local cmd = self:sendCommand("RMD", directory)
    if cmd.code == 250 then
        if self.logger then
            self.logger:info("Successfully removed directory: %s", directory)
        end
        return STATUSES.FTP.SUCCESS, "Directory removed successfully."
    else
        if self.logger then
            self.logger:error("Failed to remove directory - Code: %d", cmd.code)
        end
    end

    return STATUSES.FTP.RMDIR_FAILED, "Failed to remove directory."
end

function FTP:quit()
    if not self.connected then
        if self.logger then
            self.logger:warn("Already disconnected")
        end
        return STATUSES.FTP.NOT_CONNECTED, "Not connected."
    end

    if self.logger then
        self.logger:info("Sending QUIT command")
    end

    local cmd = self:sendCommand("QUIT")
    if cmd.code == 221 then
        self.connected = false
        self.authenticated = false

        if self.logger then
            self.logger:info("Disconnected from FTP server")
        end

        self.callbacks.onDisconnect()
        return STATUSES.FTP.SUCCESS, "Disconnected from FTP server."
    else
        if self.logger then
            self.logger:error("QUIT command failed - Code: %d", cmd.code)
        end
    end

    return STATUSES.FTP.DISCONNECT_FAILED, "Failed to disconnect."
end

function FTP:disconnect()
    return self:quit()
end

-- Alias for disconnect
function FTP:close()
    return self:disconnect()
end

function FTP:checkStatus()
    if self.connected and self.authenticated then
        return STATUSES.ftp_logged_in
    elseif self.connected then
        return STATUSES.connected
    else
        return STATUSES.disconnected
    end
end

function FTP:isConnected()
    return self.connected
end

return FTP