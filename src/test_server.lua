-- test_server.lua
-- Simple HTTP test server for network demo testing (fixed: responsive + safe terminate)

--------------------------
-- Logging (buffered)
--------------------------
local LOG_DIR = "logs"
local LOG_PATH = LOG_DIR .. "/test_server.log"

local log_buffer, log_timer, LOG_FLUSH_EVERY = {}, nil, 0.5 -- seconds

local function ensureLogDir()
    if not fs.exists(LOG_DIR) then fs.makeDir(LOG_DIR) end
end

local function flushLogBuffer()
    if #log_buffer == 0 then return end
    ensureLogDir()
    local f = fs.open(LOG_PATH, "a")
    if f then
        for i = 1, #log_buffer do f.writeLine(log_buffer[i]) end
        f.close()
    end
    log_buffer = {}
end

local function writeLog(message, level)
    level = level or "INFO"
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local entry = string.format("[%s] [%s] %s", timestamp, level, message)
    print(entry)                     -- keep console output for visibility
    table.insert(log_buffer, entry)  -- buffer writes
    -- (Re)start flush timer
    if log_timer then os.cancelTimer(log_timer) end
    log_timer = os.startTimer(LOG_FLUSH_EVERY)
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
    print("  Computer ID: " .. computerId)
    print("  Hostname:    " .. hostname)
    print("  IP:          " .. ip)
    print("  Port:        " .. port)
    print()
    print("Server endpoints:")
    print("  GET /test")
    print("  GET /info")
    print("  GET /time")
    print("  GET /echo?msg=text")
    print()
    print("Press Ctrl+T to stop server")
    print()

    logSuccess("Test server ready for connections")

    local running = true
    local request_count = 0

    -- Server loop (event-driven). We wait ONLY for rednet or timer events here.
    local function serverLoop()
        while running do
            local ev, p1, p2, p3, p4, p5 = os.pullEvent() -- block until something happens
            if ev == "rednet_message" then
                local sender, message, protocol = p1, p2, p3
                if protocol == "ccnet_http" and type(message) == "table" and message.type == "request" and message.port == port then
                    request_count = request_count + 1
                    local raw_path = message.path or "/"
                    local path = stripQuery(raw_path)
                    local method = message.method or "GET"
                    local query = parseQuery(raw_path)

                    logInfo(("HTTP request #%d: %s %s from computer %d"):format(request_count, method, raw_path, sender))

                    local response_body, response_code = "", 200

                    if path == "/test" then
                        response_body = "Test server is working!\nRequest #" .. request_count

                    elseif path == "/info" then
                        response_body = table.concat({
                            "Server Information:",
                            "Hostname: " .. hostname,
                            "Computer ID: " .. computerId,
                            "IP: " .. ip,
                            "Port: " .. port,
                            "Uptime: " .. string.format("%.2f", os.clock()) .. " seconds",
                            "Requests served: " .. request_count
                        }, "\n")

                    elseif path == "/time" then
                        response_body = "Current time: " .. os.date() .. "\nEpoch time: " .. os.epoch("utc")

                    elseif path == "/echo" then
                        local msg = query.msg
                        response_body = msg and ("Echo: " .. msg) or "Echo service - add ?msg=yourtext"

                    else
                        response_code = 404
                        response_body = "Not Found\n\nAvailable endpoints:\n/test\n/info\n/time\n/echo?msg=text"
                    end

                    local response_packet = {
                        type = "response",
                        id = message.id,
                        code = response_code,
                        headers = { ["Content-Type"] = "text/plain", ["Server"] = "CC-Test-Server/1.0" },
                        body = response_body,
                        timestamp = os.epoch("utc"),
                    }

                    rednet.send(sender, response_packet, "ccnet_http")
                    logInfo(("Sent HTTP response: %d (%d bytes)"):format(response_code, #response_body))
                end

            elseif ev == "timer" then
                local tid = p1
                if log_timer and tid == log_timer then
                    flushLogBuffer()
                    log_timer = nil
                end
            elseif ev == "terminate" then
                -- The terminate event is handled in controlLoop to keep shutdown unified.
                -- We still drop a yield here so this loop isn’t stuck doing more work.
                sleep(0)
            end
        end
    end

    -- Dedicated terminate watcher: ends the server cleanly on Ctrl+T
    local function controlLoop()
        while true do
            local ev = os.pullEventRaw()
            if ev == "terminate" then
                running = false
                break
            end
        end
    end

    -- Run both in parallel; whichever returns first stops the other.
    parallel.waitForAny(serverLoop, controlLoop)

    -- Cleanup
    logInfo("Test server shutting down")
    flushLogBuffer()
    pcall(rednet.unhost, "http_server")
    -- leave modem open for other programs if it was already open before; otherwise you could close:
    -- rednet.close(side)
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
                if info.ip then print("  http://" .. info.ip .. ":" .. port .. "/") end
                if info.hostname then print("  http://" .. info.hostname .. ".local:" .. port .. "/") end

                local ok_srv, err = pcall(function()
                    network.createServer(port, function(request)
                        local path = request.path or "/"
                        logInfo("HTTP request: " .. (request.method or "GET") .. " " .. path)
                        if path == "/test" then
                            return { code = 200, headers = {["Content-Type"]="text/plain"},
                                     body = "Test server response from " .. (info.hostname or "unknown") }
                        else
                            return { code = 200, headers = {["Content-Type"]="text/plain"},
                                     body = "Hello from " .. (info.hostname or "unknown") .. "!\nEndpoint: " .. path }
                        end
                    end)
                end)

                if ok_srv then
                    logSuccess("Network library server started successfully")
                    use_simple = false
                    -- Wait for terminate to stop
                    while true do
                        local ev = os.pullEventRaw()
                        if ev == "terminate" then break end
                    end
                else
                    logError("Network library server failed: " .. tostring(err))
                end
            else
                logError("Could not get network info; falling back")
            end
        else
            logWarning("Network daemon not running - falling back to simple server")
        end
    else
        logWarning("Network library not available - using simple server")
    end

    if use_simple then
        createSimpleServer(port)
    end

    logInfo("Test server session ended")
end

-- Run server with error handling
local ok_main, err_main = pcall(main)
if not ok_main then
    writeLog("CRITICAL: Test server failed: " .. tostring(err_main), "CRITICAL")
    print("TEST SERVER FAILURE")
    print("Error: " .. tostring(err_main))
    print("Check " .. LOG_PATH .. " for details")
    flushLogBuffer()
end
