-- test_server.lua
-- Simple HTTP test server for network demo testing

-- Logging utility
local function writeLog(message, level)
    level = level or "INFO"
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local log_entry = string.format("[%s] [%s] %s", timestamp, level, message)

    print(log_entry)

    if not fs.exists("logs") then
        fs.makeDir("logs")
    end

    local log_file = fs.open("logs/test_server.log", "a")
    if log_file then
        log_file.writeLine(log_entry)
        log_file.close()
    end
end

local function logInfo(msg) writeLog(msg, "INFO") end
local function logSuccess(msg) writeLog(msg, "SUCCESS") end
local function logWarning(msg) writeLog(msg, "WARNING") end
local function logError(msg) writeLog(msg, "ERROR") end

-- Simple HTTP server using rednet (for testing when network lib isn't available)
local function createSimpleServer(port)
    logInfo("Creating simple HTTP server on port " .. port)

    -- Find and open modem
    local modem = peripheral.find("modem")
    if not modem then
        logError("No modem found for server")
        return false
    end

    local side = peripheral.getName(modem)
    if not rednet.isOpen(side) then
        rednet.open(side)
        logInfo("Opened modem on side: " .. side)
    end

    -- Register as HTTP server
    rednet.host("http_server", "test_server_" .. os.getComputerID())
    logInfo("Registered as HTTP server")

    -- Get our info
    local computerId = os.getComputerID()
    local hostname = os.getComputerLabel() or ("test-server-" .. computerId)
    local ip = string.format("10.0.%d.%d",
            math.floor(computerId / 254) % 256,
            (computerId % 254) + 1)

    print("Test server started!")
    print("  Computer ID: " .. computerId)
    print("  Hostname: " .. hostname)
    print("  IP: " .. ip)
    print("  Port: " .. port)
    print()
    print("Server endpoints:")
    print("  GET /test - Simple test response")
    print("  GET /info - Server information")
    print("  GET /time - Current time")
    print("  GET /echo?msg=text - Echo service")
    print()
    print("Press Ctrl+T to stop server")
    print()

    logSuccess("Test server ready for connections")

    local request_count = 0

    while true do
        local sender, message, protocol = rednet.receive(0.1) -- Short timeout

        if sender and protocol == "ccnet_http" and type(message) == "table" then
            if message.type == "request" and message.port == port then
                request_count = request_count + 1
                local path = message.path or "/"
                local method = message.method or "GET"

                logInfo("HTTP request #" .. request_count .. ": " .. method .. " " .. path .. " from computer " .. sender)

                local response_body = ""
                local response_code = 200

                -- Handle different endpoints
                if path == "/test" then
                    response_body = "Test server is working!\nRequest #" .. request_count

                elseif path == "/info" then
                    response_body = "Server Information:\n" ..
                            "Hostname: " .. hostname .. "\n" ..
                            "Computer ID: " .. computerId .. "\n" ..
                            "IP: " .. ip .. "\n" ..
                            "Port: " .. port .. "\n" ..
                            "Uptime: " .. os.clock() .. " seconds\n" ..
                            "Requests served: " .. request_count

                elseif path == "/time" then
                    response_body = "Current time: " .. os.date() .. "\n" ..
                            "Epoch time: " .. os.epoch("utc")

                elseif path:match("^/echo") then
                    local msg = path:match("msg=([^&]+)")
                    if msg then
                        response_body = "Echo: " .. textutils.urlDecode(msg)
                    else
                        response_body = "Echo service - add ?msg=yourtext"
                    end

                else
                    response_code = 404
                    response_body = "Not Found\n\nAvailable endpoints:\n/test\n/info\n/time\n/echo?msg=text"
                end

                -- Send response
                local response_packet = {
                    type = "response",
                    id = message.id,
                    code = response_code,
                    headers = {
                        ["Content-Type"] = "text/plain",
                        ["Server"] = "CC-Test-Server/1.0"
                    },
                    body = response_body,
                    timestamp = os.epoch("utc")
                }

                rednet.send(sender, response_packet, "ccnet_http")
                logInfo("Sent HTTP response: " .. response_code .. " (" .. #response_body .. " bytes)")
            end
        end

        -- Check for termination
        local event = os.pullEventRaw(0)
        if event == "terminate" then
            break
        end
    end

    logInfo("Test server shutting down")
    rednet.unhost("http_server")
    return true
end

-- Try to load network library, fall back to simple server
local function main()
    print("Test Server for Network Demo")
    print("===========================")

    logInfo("Test server starting")
    logInfo("Computer ID: " .. os.getComputerID())

    local port = 80

    -- Try to use network library first
    local network_available = false
    local success, network = pcall(require, "lib.network")

    if success and network then
        logInfo("Network library available - using advanced server")

        -- Check if netd is running
        if network.isDaemonRunning() then
            logSuccess("Network daemon is running")

            -- Use network library to create server
            local info = network.getInfo()
            if info then
                print("Starting HTTP server using network library...")
                print("Server will be available at:")
                print("  http://" .. info.ip .. ":" .. port .. "/")
                print("  http://" .. info.hostname .. ".local:" .. port .. "/")

                local server_success = pcall(function()
                    network.createServer(port, function(request)
                        local path = request.path or "/"
                        logInfo("HTTP request: " .. request.method .. " " .. path)

                        if path == "/test" then
                            return {
                                code = 200,
                                headers = {["Content-Type"] = "text/plain"},
                                body = "Test server response from " .. info.hostname
                            }
                        else
                            return {
                                code = 200,
                                headers = {["Content-Type"] = "text/plain"},
                                body = "Hello from " .. info.hostname .. "!\nEndpoint: " .. path
                            }
                        end
                    end)
                end)

                if server_success then
                    logSuccess("Network library server started successfully")
                else
                    logError("Network library server failed")
                    network_available = false
                end
            else
                logError("Could not get network info")
                network_available = false
            end
        else
            logWarning("Network daemon not running - falling back to simple server")
            network_available = false
        end
    else
        logWarning("Network library not available - using simple server")
        network_available = false
    end

    -- Fall back to simple rednet-based server
    if not network_available then
        createSimpleServer(port)
    end

    logInfo("Test server session ended")
end

-- Run server with error handling
local server_success, server_error = pcall(main)

if not server_success then
    writeLog("CRITICAL: Test server failed: " .. tostring(server_error), "CRITICAL")
    print("TEST SERVER FAILURE")
    print("Error: " .. tostring(server_error))
    print("Check logs/test_server.log for details")
end