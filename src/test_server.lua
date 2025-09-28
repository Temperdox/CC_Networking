#!/usr/bin/env lua
-- test_server.lua
-- Standalone HTTP test server - works independently of hardware_watchdog

-- Prevent accidental execution as hardware_watchdog
if arg and arg[0] and arg[0]:match("hardware_watchdog") then
    print("Error: This is test_server.lua, not hardware_watchdog")
    print("Hardware watchdog should already be running from startup")
    return
end

--------------------------
-- Dual Logging System
--------------------------
local LOG_DIR = "logs"
local LOG_PATH = LOG_DIR .. "/test_server.log"
local CONSOLE_LOG_PATH = LOG_DIR .. "/test_server_console.log"

local log_buffer = {}
local console_buffer = {}
local LOG_FLUSH_INTERVAL = 0.5
local last_flush = os.clock()

local function ensureLogDir()
    if not fs.exists(LOG_DIR) then fs.makeDir(LOG_DIR) end
end

local function flushLogBuffer()
    ensureLogDir()

    if #log_buffer > 0 then
        local f = fs.open(LOG_PATH, "a")
        if f then
            for i = 1, #log_buffer do
                f.writeLine(log_buffer[i])
            end
            f.close()
        end
        log_buffer = {}
    end

    if #console_buffer > 0 then
        local f = fs.open(CONSOLE_LOG_PATH, "a")
        if f then
            for i = 1, #console_buffer do
                f.writeLine(console_buffer[i])
            end
            f.close()
        end
        console_buffer = {}
    end

    last_flush = os.clock()
end

-- Override print to capture console output
local originalPrint = print
local function print(...)
    originalPrint(...)

    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local args = {...}
    local msg = ""
    for i = 1, #args do
        if i > 1 then msg = msg .. "\t" end
        msg = msg .. tostring(args[i])
    end

    local entry = string.format("[%s] %s", timestamp, msg)
    table.insert(console_buffer, entry)

    if os.clock() - last_flush > LOG_FLUSH_INTERVAL then
        flushLogBuffer()
    end
end

local function writeLog(message, level)
    level = level or "INFO"
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local entry = string.format("[%s] [%s] %s", timestamp, level, message)
    print(entry)
    table.insert(log_buffer, entry)

    if os.clock() - last_flush > LOG_FLUSH_INTERVAL then
        flushLogBuffer()
    end
end

local function logInfo(msg)    writeLog(msg, "INFO")    end
local function logSuccess(msg) writeLog(msg, "SUCCESS") end
local function logWarning(msg) writeLog(msg, "WARNING") end
local function logError(msg)   writeLog(msg, "ERROR")   end

--------------------------
-- Utility Functions
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
-- Simple Rednet HTTP Server
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
    local hostname = os.getComputerLabel() or ("cc-" .. computerId)
    local ip = string.format("10.0.%d.%d",
            math.floor(computerId / 254) % 256,
            (computerId % 254) + 1)

    print("Server is running!")
    print(string.format("  Hostname: %s", hostname))
    print(string.format("  IP: %s", ip))
    print(string.format("  Port: %d", port))
    print()
    print("Available endpoints:")
    print("  /       - Server info")
    print("  /test   - Test endpoint")
    print("  /info   - JSON server info")
    print("  /time   - Current time")
    print("  /echo   - Echo service")
    print()

    logInfo("Test server session started")
    logInfo("Computer ID: " .. computerId)
    logInfo("Hostname: " .. hostname)
    logInfo("IP: " .. ip)
    logInfo("Port: " .. port)

    local running = true
    local request_count = 0
    local start_time = os.epoch("utc")

    -- Main server loop
    while running do
        local ev, p1, p2, p3 = os.pullEventRaw()

        if ev == "terminate" then
            running = false
            logInfo("Received terminate signal")

        elseif ev == "rednet_message" then
            local sender, message, protocol = p1, p2, p3

            -- Handle HTTP requests
            if (protocol == "ccnet_http" or protocol == "network_adapter_http") and
                    type(message) == "table" and
                    (message.type == "request" or message.type == "http_request") then

                request_count = request_count + 1
                local method = message.method or "GET"
                local path = message.path or "/"
                local headers = message.headers or {}
                local body = message.body or ""

                logInfo(string.format("Request #%d from ID %d: %s %s",
                        request_count, sender, method, path))

                -- Parse the request
                local clean_path = stripQuery(path)
                local query = parseQuery(path)

                -- Prepare response
                local response_code = 200
                local response_body = ""
                local response_headers = {
                    ["Content-Type"] = "text/plain",
                    ["Server"] = "CC-Test-Server/1.0"
                }

                -- Route handling
                if clean_path == "/" then
                    response_body = string.format(
                            "CC Test Server v1.0\n" ..
                                    "===================\n" ..
                                    "Server: %s (%s)\n" ..
                                    "Port: %d\n" ..
                                    "Uptime: %d seconds\n" ..
                                    "Requests: %d\n" ..
                                    "Time: %s\n\n" ..
                                    "Available endpoints:\n" ..
                                    "  /test - Test endpoint\n" ..
                                    "  /info - Server information\n" ..
                                    "  /time - Current time\n" ..
                                    "  /echo?msg=text - Echo service",
                            hostname, ip, port,
                            math.floor((os.epoch("utc") - start_time) / 1000),
                            request_count, os.date()
                    )

                elseif clean_path == "/test" then
                    response_body = "Test successful! Server is responding."

                elseif clean_path == "/info" then
                    response_headers["Content-Type"] = "application/json"
                    response_body = textutils.serialiseJSON({
                        server = "CC-Test-Server/1.0",
                        hostname = hostname,
                        ip = ip,
                        port = port,
                        computer_id = computerId,
                        requests = request_count,
                        uptime = math.floor((os.epoch("utc") - start_time) / 1000)
                    })

                elseif clean_path == "/time" then
                    response_body = string.format("Server time: %s\nEpoch: %d ms",
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
                    headers = response_headers,
                    body = response_body,
                    timestamp = os.epoch("utc"),
                }

                -- Use the same protocol for response
                rednet.send(sender, response_packet, protocol)
                logInfo(string.format("Sent HTTP response: %d (%d bytes)",
                        response_code, #response_body))

                -- Flush logs periodically
                if request_count % 5 == 0 then
                    flushLogBuffer()
                end
            end
        end

        -- Periodic log flush
        if os.clock() - last_flush > LOG_FLUSH_INTERVAL then
            flushLogBuffer()
        end
    end

    -- Cleanup
    logInfo("Test server shutting down")
    logInfo(string.format("Total requests handled: %d", request_count))
    logInfo("Test server session ended")
    logSuccess("Server stopped gracefully")

    flushLogBuffer()
    pcall(rednet.unhost, "http_server")

    print()
    print("Server stopped")
    print(string.format("Handled %d requests", request_count))

    return true
end

--------------------------
-- Main Entry Point
--------------------------
local function main()
    print("========================================")
    print("Standalone HTTP Test Server")
    print("========================================")
    print()

    -- Check for hardware watchdog (informational only)
    if fs.exists("/var/run/hardware_watchdog.pid") then
        print("✓ Hardware watchdog is running")
    else
        print("⚠ Hardware watchdog is not running")
        print("  (This is OK - server can run without it)")
    end

    -- Check for netd
    if fs.exists("/var/run/netd.pid") then
        print("✓ Network daemon (netd) is running")
    else
        print("⚠ Network daemon (netd) is not running")
        print("  Server will use basic rednet mode")
    end

    print()
    print("Starting server...")
    print("Press Ctrl+T to stop")
    print("========================================")
    print()

    logInfo("Test server launcher started")
    logInfo("Computer ID: " .. os.getComputerID())
    logInfo("Computer Label: " .. (os.getComputerLabel() or "None"))

    -- Always use simple server mode to avoid dependencies
    local port = 80
    createSimpleServer(port)

    print()
    print("Logs saved to:")
    print("  " .. LOG_PATH .. " (events)")
    print("  " .. CONSOLE_LOG_PATH .. " (console)")

    flushLogBuffer()
end

-- Ensure we're not being run as hardware_watchdog
if shell and shell.getRunningProgram() == "hardware_watchdog" then
    print("Error: Wrong program!")
    print("This is test_server.lua, not hardware_watchdog.lua")
    print("Hardware watchdog should already be running from startup")
    return
end

-- Run the server
local ok, err = pcall(main)
if not ok then
    logError("Test server error: " .. tostring(err))
    print()
    print("SERVER ERROR!")
    print("Error: " .. tostring(err))
    flushLogBuffer()
    error(err)
end

flushLogBuffer()