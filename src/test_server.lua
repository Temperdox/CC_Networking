-- test_server.lua
-- Simple HTTP test server for network demo testing (fixed logging and terminate handling)

--------------------------
-- Logging (buffered with proper flushing)
--------------------------
local LOG_DIR = "logs"
local LOG_PATH = LOG_DIR .. "/test_server.log"

local log_buffer = {}
local LOG_FLUSH_INTERVAL = 0.5 -- seconds
local last_flush = os.clock()

local function ensureLogDir()
    if not fs.exists(LOG_DIR) then fs.makeDir(LOG_DIR) end
end

local function flushLogBuffer()
    if #log_buffer == 0 then return end
    ensureLogDir()
    local f = fs.open(LOG_PATH, "a")
    if f then
        for i = 1, #log_buffer do
            f.writeLine(log_buffer[i])
        end
        f.close()
    end
    log_buffer = {}
    last_flush = os.clock()
end

local function writeLog(message, level)
    level = level or "INFO"
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local entry = string.format("[%s] [%s] %s", timestamp, level, message)
    print(entry)                     -- keep console output for visibility
    table.insert(log_buffer, entry)  -- buffer writes

    -- Check if we should flush based on time elapsed
    if os.clock() - last_flush > LOG_FLUSH_INTERVAL then
        flushLogBuffer()
    end
end

local function logInfo(msg)    writeLog(msg, "INFO")    end
local function logSuccess(msg) writeLog(msg, "SUCCESS") end
local function logWarning(msg) writeLog(msg, "WARNING") end
local function logError(msg)   writeLog(msg, "ERROR")   end

--------------------------
-- Utility
--------------------------
local function parseQuery(path)
    local q = {}
    local qs = path:match("%?(.*)$")
    if not qs then return q end
    for pair in qs:gmatch("[^&]+") do
        local k, v = pair:match("([^=]+)=?(.*)")
        if k then
            q[k] = textutils.urlDecode(v or "")
        end
    end
    return q
end

local function stripQuery(path)
    return (path:gsub("%?.*$",""))
end

--------------------------
-- Simple HTTP server via rednet
--------------------------
local function createSimpleServer(port)
    logInfo("Creating simple HTTP server on port " .. port)

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

    rednet.host("http_server", "test_server_" .. os.getComputerID())
    logInfo("Registered as HTTP server")

    local computerId = os.getComputerID()
    local hostname = os.getComputerLabel() or ("test-server-" .. computerId)
    local ip = string.format("10.0.%d.%d", math.floor(computerId / 254) % 256, (computerId % 254) + 1)

    print("Test server started!")
    print(string.format("  Hostname: %s", hostname))
    print(string.format("  IP: %s", ip))
    print(string.format("  Port: %d", port))
    print("Server will be available at:")
    print(string.format("  http://%s/", hostname))
    print(string.format("  http://%s:%d/", ip, port))
    print("Press Ctrl+T to stop the server")
    print("----------------------------------------")

    logInfo("Test server session started")
    logInfo("Computer ID: " .. computerId)
    logInfo("Hostname: " .. hostname)
    logInfo("IP: " .. ip)
    logInfo("Port: " .. port)

    local running = true
    local request_count = 0

    -- Main server loop
    while running do
        -- Use pullEventRaw to catch terminate
        local ev, p1, p2, p3 = os.pullEventRaw()

        if ev == "terminate" then
            running = false
            logInfo("Received terminate signal")
        elseif ev == "rednet_message" then
            local sender, message, protocol = p1, p2, p3

            -- Check for HTTP requests
            if protocol == "ccnet_http" and type(message) == "table" and message.type == "request" then
                request_count = request_count + 1
                local method = message.method or "GET"
                local path = message.path or "/"
                local headers = message.headers or {}
                local body = message.body or ""

                logInfo(string.format("Request #%d from ID %d: %s %s",
                        request_count, sender, method, path))

                -- Parse the request path
                local clean_path = stripQuery(path)
                local query = parseQuery(path)

                -- Prepare response
                local response_code = 200
                local response_body = ""

                -- Route handling
                if clean_path == "/" then
                    response_body = string.format(
                            "CC Test Server v1.0\n" ..
                                    "===================\n" ..
                                    "Server: %s (%s)\n" ..
                                    "Uptime: %d seconds\n" ..
                                    "Requests: %d\n" ..
                                    "Time: %s\n\n" ..
                                    "Available endpoints:\n" ..
                                    "/test - Test endpoint\n" ..
                                    "/info - Server information\n" ..
                                    "/time - Current time\n" ..
                                    "/echo?msg=text - Echo service",
                            hostname, ip, os.clock(), request_count, os.date()
                    )
                elseif clean_path == "/test" then
                    response_body = "Test successful! Server is responding."
                elseif clean_path == "/info" then
                    response_body = textutils.serialiseJSON({
                        server = "CC-Test-Server/1.0",
                        hostname = hostname,
                        ip = ip,
                        port = port,
                        requests = request_count,
                        uptime = os.clock()
                    })
                elseif clean_path == "/time" then
                    response_body = string.format("Server time: %s\nEpoch: %d",
                            os.date(), os.epoch("utc"))
                elseif clean_path == "/echo" then
                    local msg = query.msg or "No message provided"
                    response_body = "Echo: " .. msg
                else
                    response_code = 404
                    response_body = "404 Not Found\n\nAvailable endpoints:\n/test\n/info\n/time\n/echo?msg=text"
                end

                -- Send response
                local response_packet = {
                    type = "response",
                    id = message.id,
                    code = response_code,
                    headers = {
                        ["Content-Type"] = "text/plain",
                        ["Server"] = "CC-Test-Server/1.0",
                        ["Content-Length"] = tostring(#response_body)
                    },
                    body = response_body,
                    timestamp = os.epoch("utc"),
                }

                rednet.send(sender, response_packet, "ccnet_http")
                logInfo(string.format("Sent HTTP response: %d (%d bytes)",
                        response_code, #response_body))

                -- Flush logs periodically
                if request_count % 5 == 0 then
                    flushLogBuffer()
                end
            end
        end

        -- Periodic log flush check (non-blocking)
        if os.clock() - last_flush > LOG_FLUSH_INTERVAL then
            flushLogBuffer()
        end
    end

    -- Cleanup
    logInfo("Test server shutting down")
    logInfo(string.format("Total requests handled: %d", request_count))
    logInfo("Test server session ended")
    logSuccess("Server stopped gracefully")

    -- Final flush
    flushLogBuffer()

    pcall(rednet.unhost, "http_server")
    print("\n[Test Server] Stopped")

    return true
end

--------------------------
-- Main
--------------------------
local function main()
    print("Test Server for Network Demo")
    print("===========================")

    logInfo("Test server starting")
    logInfo("Computer ID: " .. os.getComputerID())

    local port = 80

    -- Try network library first
    local use_simple = true
    local ok_req, network = pcall(require, "lib.network")
    if ok_req and network then
        local ok_daemon, isUp = pcall(network.isDaemonRunning)
        if ok_daemon and isUp then
            logSuccess("Network daemon is running")
            local info = nil
            local ok_info, res = pcall(network.getInfo)
            if ok_info then info = res end
            if info then
                print("Starting HTTP server using network library...")
                print("Server will be available at:")
                print(string.format("  http://%s:%d/", info.hostname or "unknown", port))
                print(string.format("  http://%s:%d/", info.ip or "unknown", port))

                local ok_serve, err = pcall(network.serveHTTP, port, function(request)
                    logInfo(string.format("Request: %s %s", request.method, request.path))

                    -- Simple routing
                    local path = stripQuery(request.path)
                    local query = parseQuery(request.path)

                    if path == "/" then
                        return 200, "Test Server Running!\n\nAvailable:\n/test\n/info\n/time\n/echo?msg=text"
                    elseif path == "/test" then
                        return 200, "Test successful!"
                    elseif path == "/info" then
                        return 200, textutils.serialiseJSON(info)
                    elseif path == "/time" then
                        return 200, os.date()
                    elseif path == "/echo" then
                        return 200, "Echo: " .. (query.msg or "empty")
                    else
                        return 404, "Not Found"
                    end
                end)

                if not ok_serve then
                    logWarning("Network library HTTP failed: " .. tostring(err))
                    use_simple = true
                else
                    use_simple = false
                end
            else
                logWarning("Could not get network info, using simple server")
            end
        else
            logWarning("Network daemon not running, using simple server")
        end
    else
        logInfo("Network library not available, using simple server")
    end

    if use_simple then
        print("Starting simple HTTP server using rednet...")
        createSimpleServer(port)
    end

    logSuccess("Test server stopped")
    flushLogBuffer()
end

-- Run with error handling
local ok, err = pcall(main)
if not ok then
    logError("Test server error: " .. tostring(err))
    flushLogBuffer()
    error(err)
end