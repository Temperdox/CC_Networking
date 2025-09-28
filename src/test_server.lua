-- test_server.lua
-- Enhanced HTTP test server with launcher integration and Basalt XML support
-- Works independently but integrates with test infrastructure

-- Prevent accidental execution as hardware_watchdog
if arg and arg[0] and arg[0]:match("hardware_watchdog") then
    print("Error: This is test_server.lua, not hardware_watchdog")
    print("Hardware watchdog should already be running from startup")
    return
end

--------------------------
-- Server State Management
--------------------------
local server = {
    version = "1.2.0",
    running = false,
    stats = {
        requests = 0,
        errors = 0,
        start_time = 0,
        last_request = 0
    },
    config = {
        port = 80,
        host = "0.0.0.0",
        enable_basalt_xml = true,
        log_requests = true
    }
}

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
    if not fs.exists("/var/log") then fs.makeDir("/var/log") end
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
            q[k] = textutils.urlDecode and textutils.urlDecode(v or "") or (v or "")
        end
    end
    return q
end

local function stripQuery(path)
    return (path:gsub("%?.*$",""))
end

-- Create Basalt XML response
local function createBasaltXML(title, elements)
    local xml = string.format([[
<basalt>
    <frame name="main" x="1" y="1" width="51" height="19" background="blue">
        <label name="title" x="2" y="2" text="%s" foreground="white"/>
        %s
    </frame>
</basalt>]], title, table.concat(elements, "\n        "))
    return xml
end

-- Check if client prefers Basalt XML
local function prefersXML(headers)
    local accept = headers and headers["accept"] or ""
    return accept:match("application/xml") or accept:match("text/xml") or server.config.enable_basalt_xml
end

--------------------------
-- Route Handlers
--------------------------
local routes = {}

routes["/"] = function(query, headers)
    local computerId = os.getComputerID()
    local hostname = os.getComputerLabel() or ("cc-" .. computerId)
    local uptime = math.floor((os.epoch("utc") - server.stats.start_time) / 1000)

    if prefersXML(headers) then
        local elements = {
            '<label name="server_info" x="2" y="4" text="CC Test Server v' .. server.version .. '" foreground="lime"/>',
            '<label name="hostname" x="2" y="5" text="Host: ' .. hostname .. '" foreground="cyan"/>',
            '<label name="computer_id" x="2" y="6" text="ID: ' .. computerId .. '" foreground="cyan"/>',
            '<label name="port" x="2" y="7" text="Port: ' .. server.config.port .. '" foreground="white"/>',
            '<label name="uptime" x="2" y="8" text="Uptime: ' .. uptime .. 's" foreground="white"/>',
            '<label name="requests" x="2" y="9" text="Requests: ' .. server.stats.requests .. '" foreground="white"/>',
            '<label name="endpoints" x="2" y="11" text="Available Endpoints:" foreground="yellow"/>',
            '<label name="ep1" x="3" y="12" text="/test - Test endpoint" foreground="white"/>',
            '<label name="ep2" x="3" y="13" text="/info - Server info (JSON)" foreground="white"/>',
            '<label name="ep3" x="3" y="14" text="/time - Current time" foreground="white"/>',
            '<label name="ep4" x="3" y="15" text="/echo?msg=text - Echo service" foreground="white"/>',
            '<button name="test_btn" x="2" y="17" width="8" height="1" text="Test" background="green"/>',
            '<button name="info_btn" x="11" y="17" width="8" height="1" text="Info" background="orange"/>',
            '<button name="time_btn" x="20" y="17" width="8" height="1" text="Time" background="cyan"/>'
        }

        return 200, {["Content-Type"] = "application/xml"}, createBasaltXML("CC Test Server", elements)
    else
        local body = string.format(
                "CC Test Server v%s\n" ..
                        "===================\n" ..
                        "Server: %s (ID: %d)\n" ..
                        "Port: %d\n" ..
                        "Uptime: %d seconds\n" ..
                        "Requests: %d\n" ..
                        "Time: %s\n\n" ..
                        "Available endpoints:\n" ..
                        "  /test - Test endpoint\n" ..
                        "  /info - Server information (JSON)\n" ..
                        "  /time - Current time\n" ..
                        "  /echo?msg=text - Echo service\n" ..
                        "  /status - Server status (XML)\n",
                server.version, hostname, computerId, server.config.port,
                uptime, server.stats.requests, os.date()
        )
        return 200, {["Content-Type"] = "text/plain"}, body
    end
end

routes["/test"] = function(query, headers)
    if prefersXML(headers) then
        local elements = {
            '<label name="success" x="2" y="4" text="Test Successful!" foreground="lime"/>',
            '<label name="message" x="2" y="5" text="Server is responding correctly" foreground="white"/>',
            '<label name="timestamp" x="2" y="6" text="Time: ' .. os.date("%H:%M:%S") .. '" foreground="yellow"/>',
            '<label name="request_id" x="2" y="7" text="Request #' .. (server.stats.requests + 1) .. '" foreground="cyan"/>',
            '<button name="back_btn" x="2" y="9" width="8" height="1" text="Back" background="gray"/>'
        }
        return 200, {["Content-Type"] = "application/xml"}, createBasaltXML("Test Result", elements)
    else
        return 200, {["Content-Type"] = "text/plain"}, "Test successful! Server is responding correctly."
    end
end

routes["/info"] = function(query, headers)
    local computerId = os.getComputerID()
    local hostname = os.getComputerLabel() or ("cc-" .. computerId)
    local uptime = math.floor((os.epoch("utc") - server.stats.start_time) / 1000)

    local info = {
        server = "CC-Test-Server/" .. server.version,
        hostname = hostname,
        computer_id = computerId,
        port = server.config.port,
        requests = server.stats.requests,
        errors = server.stats.errors,
        uptime = uptime,
        memory_usage = math.floor(collectgarbage("count")),
        timestamp = os.epoch("utc"),
        features = {
            basalt_xml = server.config.enable_basalt_xml,
            logging = server.config.log_requests
        }
    }

    return 200, {["Content-Type"] = "application/json"}, textutils.serializeJSON(info)
end

routes["/time"] = function(query, headers)
    if prefersXML(headers) then
        local elements = {
            '<label name="current_time" x="2" y="4" text="Current Time:" foreground="yellow"/>',
            '<label name="formatted" x="2" y="5" text="' .. os.date("%Y-%m-%d %H:%M:%S") .. '" foreground="lime"/>',
            '<label name="epoch" x="2" y="6" text="Epoch: ' .. os.epoch("utc") .. '" foreground="white"/>',
            '<label name="day" x="2" y="7" text="Day: ' .. os.day() .. '" foreground="white"/>',
            '<label name="time_decimal" x="2" y="8" text="Time: ' .. string.format("%.2f", os.time()) .. '" foreground="white"/>',
            '<button name="refresh_btn" x="2" y="10" width="10" height="1" text="Refresh" background="blue"/>',
            '<button name="back_btn" x="13" y="10" width="8" height="1" text="Back" background="gray"/>'
        }
        return 200, {["Content-Type"] = "application/xml"}, createBasaltXML("Server Time", elements)
    else
        local body = string.format("Server time: %s\nEpoch: %d ms\nDay: %d\nTime: %.2f",
                os.date(), os.epoch("utc"), os.day(), os.time())
        return 200, {["Content-Type"] = "text/plain"}, body
    end
end

routes["/echo"] = function(query, headers)
    local msg = query.msg or "No message provided"

    if prefersXML(headers) then
        local elements = {
            '<label name="echo_title" x="2" y="4" text="Echo Service" foreground="yellow"/>',
            '<label name="original" x="2" y="5" text="Original: ' .. msg .. '" foreground="white"/>',
            '<label name="echo" x="2" y="6" text="Echo: ' .. msg .. '" foreground="lime"/>',
            '<label name="length" x="2" y="7" text="Length: ' .. #msg .. ' characters" foreground="cyan"/>',
            '<textfield name="new_msg" x="2" y="9" width="30" height="1" placeholder="Enter new message"/>',
            '<button name="echo_btn" x="2" y="11" width="10" height="1" text="Echo New" background="green"/>',
            '<button name="back_btn" x="13" y="11" width="8" height="1" text="Back" background="gray"/>'
        }
        return 200, {["Content-Type"] = "application/xml"}, createBasaltXML("Echo Service", elements)
    else
        return 200, {["Content-Type"] = "text/plain"}, "Echo: " .. msg
    end
end

routes["/status"] = function(query, headers)
    local elements = {
        '<label name="status" x="2" y="4" text="Server Status: ONLINE" foreground="lime"/>',
        '<label name="version" x="2" y="5" text="Version: ' .. server.version .. '" foreground="white"/>',
        '<label name="uptime" x="2" y="6" text="Uptime: ' .. math.floor((os.epoch("utc") - server.stats.start_time) / 1000) .. 's" foreground="white"/>',
        '<label name="requests" x="2" y="7" text="Total Requests: ' .. server.stats.requests .. '" foreground="white"/>',
        '<label name="errors" x="2" y="8" text="Errors: ' .. server.stats.errors .. '" foreground="red"/>',
        '<label name="memory" x="2" y="9" text="Memory: ' .. math.floor(collectgarbage("count")) .. ' KB" foreground="cyan"/>',
        '<button name="refresh_btn" x="2" y="11" width="10" height="1" text="Refresh" background="blue"/>',
        '<button name="gc_btn" x="13" y="11" width="12" height="1" text="Collect GC" background="orange"/>'
    }
    return 200, {["Content-Type"] = "application/xml"}, createBasaltXML("Server Status", elements)
end

--------------------------
-- HTTP Request Handler
--------------------------
local function handleHTTPRequest(request, sender)
    server.stats.requests = server.stats.requests + 1
    server.stats.last_request = os.epoch("utc")

    local method = request.method or "GET"
    local path = request.path or "/"
    local headers = request.headers or {}
    local body = request.body or ""

    if server.config.log_requests then
        logInfo(string.format("Request #%d from ID %d: %s %s",
                server.stats.requests, sender, method, path))
    end

    -- Parse the request
    local clean_path = stripQuery(path)
    local query = parseQuery(path)

    -- Find and execute route handler
    local handler = routes[clean_path]
    local response_code, response_headers, response_body

    if handler then
        local ok, code, headers_or_error, body = pcall(handler, query, headers)
        if ok then
            response_code = code
            response_headers = headers_or_error or {}
            response_body = body or ""
        else
            server.stats.errors = server.stats.errors + 1
            logError("Handler error for " .. clean_path .. ": " .. tostring(headers_or_error))
            response_code = 500
            response_headers = {["Content-Type"] = "text/plain"}
            response_body = "Internal Server Error"
        end
    else
        response_code = 404
        response_headers = {["Content-Type"] = "text/plain"}
        response_body = "404 Not Found\n\nAvailable endpoints:\n" ..
                table.concat({"/", "/test", "/info", "/time", "/echo?msg=text", "/status"}, "\n")
    end

    -- Add standard headers
    response_headers["Server"] = "CC-Test-Server/" .. server.version
    response_headers["Date"] = os.date("%a, %d %b %Y %H:%M:%S GMT")
    if not response_headers["Content-Length"] then
        response_headers["Content-Length"] = tostring(#response_body)
    end

    return {
        type = "response",
        id = request.id,
        code = response_code,
        headers = response_headers,
        body = response_body,
        timestamp = os.epoch("utc")
    }
end

--------------------------
-- Server Implementation
--------------------------
local function createServer(port)
    server.config.port = port or server.config.port
    server.stats.start_time = os.epoch("utc")

    logInfo("Starting CC Test Server v" .. server.version)
    logInfo("Port: " .. server.config.port)

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

    -- Register with netd if available
    if _G.network_state and _G.network_state.servers then
        _G.network_state.servers[server.config.port] = {
            handler = function(req)
                return handleHTTPRequest(req, req.source or 0)
            end,
            type = "http",
            started = server.stats.start_time
        }
        logInfo("Registered with netd on port " .. server.config.port)
    end

    rednet.host("http_server", "test_server_" .. os.getComputerID())
    logInfo("Registered as HTTP server")

    local computerId = os.getComputerID()
    local hostname = os.getComputerLabel() or ("cc-" .. computerId)
    local ip = string.format("10.0.%d.%d",
            math.floor(computerId / 254) % 256,
            (computerId % 254) + 1)

    server.running = true

    print("Server is running!")
    print(string.format("  Hostname: %s", hostname))
    print(string.format("  IP: %s", ip))
    print(string.format("  Port: %d", server.config.port))
    print("  Basalt XML: " .. (server.config.enable_basalt_xml and "Enabled" or "Disabled"))
    print()
    print("Available endpoints:")
    for path, _ in pairs(routes) do
        print("  " .. path)
    end
    print()

    logSuccess("Test server started successfully")
    logInfo("Computer ID: " .. computerId)
    logInfo("Hostname: " .. hostname)
    logInfo("IP: " .. ip)

    return true
end

local function serverLoop()
    while server.running do
        local ev, p1, p2, p3 = os.pullEventRaw()

        if ev == "terminate" then
            server.running = false
            logInfo("Received terminate signal")

        elseif ev == "rednet_message" then
            local sender, message, protocol = p1, p2, p3

            -- Handle HTTP requests
            if (protocol == "ccnet_http" or protocol == "network_adapter_http" or protocol == "network_packet") and
                    type(message) == "table" and
                    (message.type == "request" or message.type == "http_request") then

                local response = handleHTTPRequest(message, sender)
                rednet.send(sender, response, protocol)

                if server.config.log_requests then
                    logInfo(string.format("Sent HTTP response: %d (%d bytes)",
                            response.code, #response.body))
                end
            end
        end

        -- Periodic log flush and maintenance
        if os.clock() - last_flush > LOG_FLUSH_INTERVAL then
            flushLogBuffer()

            -- Periodic garbage collection
            if server.stats.requests % 50 == 0 and server.stats.requests > 0 then
                collectgarbage()
            end
        end
    end
end

local function stopServer()
    if not server.running then
        return false
    end

    server.running = false

    -- Unregister from netd
    if _G.network_state and _G.network_state.servers then
        _G.network_state.servers[server.config.port] = nil
    end

    logInfo("Test server shutting down")
    logInfo(string.format("Total requests handled: %d", server.stats.requests))
    logInfo(string.format("Total errors: %d", server.stats.errors))
    logSuccess("Server stopped gracefully")

    flushLogBuffer()
    pcall(rednet.unhost, "http_server")

    print()
    print("Server stopped")
    print(string.format("Handled %d requests (%d errors)", server.stats.requests, server.stats.errors))

    return true
end

--------------------------
-- Public API (for launcher integration)
--------------------------
server.start = function()
    if server.running then
        return false, "Server already running"
    end

    local success = createServer()
    if success then
        -- Run in coroutine for launcher integration
        if _G.server_launcher then
            coroutine.wrap(serverLoop)()
        end
        return true, "Server started successfully"
    else
        return false, "Failed to start server"
    end
end

server.stop = stopServer

server.getStats = function()
    return {
        running = server.running,
        port = server.config.port,
        requests = server.stats.requests,
        errors = server.stats.errors,
        uptime = server.running and (os.epoch("utc") - server.stats.start_time) or 0,
        memory_usage = math.floor(collectgarbage("count"))
    }
end

server.test = function()
    print("Running HTTP server self-test...")
    -- Basic self-test implementation
    local testsPassed = 0
    local totalTests = 1

    -- Test 1: Server status
    if server.running then
        print("✓ Server is running")
        testsPassed = testsPassed + 1
    else
        print("✗ Server is not running")
    end

    print(string.format("Self-test completed: %d/%d tests passed", testsPassed, totalTests))
    return testsPassed == totalTests
end

--------------------------
-- Main Entry Point
--------------------------
local function main()
    print("========================================")
    print("Enhanced CC Test Server v" .. server.version)
    print("========================================")
    print()

    -- Check system status
    if fs.exists("/var/run/hardware_watchdog.pid") then
        print("✓ Hardware watchdog is running")
    else
        print("⚠ Hardware watchdog is not running")
    end

    if fs.exists("/var/run/netd.pid") then
        print("✓ Network daemon (netd) is running")
    else
        print("⚠ Network daemon not running - using standalone mode")
    end

    -- Check for Basalt
    local hasBasalt = pcall(require, "basalt")
    if hasBasalt then
        print("✓ Basalt GUI framework available")
        server.config.enable_basalt_xml = true
    else
        print("⚠ Basalt not available - XML responses disabled")
        server.config.enable_basalt_xml = false
    end

    print()
    print("Starting server...")
    print("Press Ctrl+T to stop")
    print("========================================")
    print()

    logInfo("Test server launcher started")

    local success = createServer(80)
    if success then
        serverLoop()
    else
        logError("Failed to start server")
        return false
    end

    flushLogBuffer()
    return true
end

-- Export for launcher integration
if not _G.test_http_server then
    _G.test_http_server = server
end

-- Auto-start if run directly
if not _G.server_launcher and not _G.network_test_client then
    local ok, err = pcall(main)
    if not ok then
        logError("Test server error: " .. tostring(err))
        print("SERVER ERROR: " .. tostring(err))
        flushLogBuffer()
        error(err)
    end
end

return server