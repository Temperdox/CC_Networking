-- /tests/servers/udp_server.lua
-- UDP Test Server for ComputerCraft Network System
-- Provides UDP protocol testing with various services

local server = {}
server.version = "1.0.0"
server.running = false
server.sockets = {}
server.stats = { packets = 0, bytes = 0, errors = 0 }
server.start_time = os.epoch("utc")

-- Load UDP protocol
local udp = nil
if fs.exists("/protocols/udp.lua") then
    udp = dofile("/protocols/udp.lua")
elseif _G.netd_udp then
    udp = _G.netd_udp
end

-- Server configuration
local config = {
    echo_port = 7,      -- Standard echo port
    time_port = 37,     -- Time service port
    custom_port = 12345, -- Custom test port
    discovery_port = 1900, -- Discovery service
    log_packets = true
}

-- Simple logging
local function log(level, message, ...)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local formatted = string.format("[%s] UDP Server %s: %s", timestamp, level, string.format(message, ...))
    print(formatted)

    if not fs.exists("/var/log") then fs.makeDir("/var/log") end
    local logFile = fs.open("/var/log/udp_server.log", "a")
    if logFile then
        logFile.writeLine(formatted)
        logFile.close()
    end
end

-- Service handlers
local services = {}

-- Echo service (RFC 862)
services.echo = function(socket, data, sender)
    -- Simply echo back the received data
    socket:send(data, sender.ip, sender.port)
    server.stats.packets = server.stats.packets + 1
    server.stats.bytes = server.stats.bytes + #data

    if config.log_packets then
        log("DEBUG", "Echo: %d bytes from %s:%d", #data, sender.ip, sender.port)
    end

    return "Echoed " .. #data .. " bytes"
end

-- Time service (RFC 868)
services.time = function(socket, data, sender)
    -- Send current time as 32-bit seconds since 1900
    local currentTime = os.epoch("utc") / 1000 + 2208988800 -- Unix epoch to NTP epoch
    local timeBytes = string.pack(">I4", math.floor(currentTime))

    socket:send(timeBytes, sender.ip, sender.port)
    server.stats.packets = server.stats.packets + 1
    server.stats.bytes = server.stats.bytes + 4

    log("DEBUG", "Time service: sent time to %s:%d", sender.ip, sender.port)
    return "Sent time: " .. os.date("%H:%M:%S")
end

-- Custom test service
services.custom = function(socket, data, sender)
    local response = ""

    -- Parse command
    if data:match("^ping") then
        response = "pong " .. os.epoch("utc")

    elseif data:match("^time") then
        response = "time " .. os.date("%Y-%m-%d %H:%M:%S") .. " utc"

    elseif data:match("^stats") then
        response = string.format("stats packets:%d bytes:%d uptime:%d errors:%d",
                server.stats.packets, server.stats.bytes,
                os.epoch("utc") - server.start_time, server.stats.errors)

    elseif data:match("^echo (.+)") then
        local message = data:match("^echo (.+)")
        response = "echo_response " .. message

    elseif data:match("^load") then
        -- Simulated load test - send multiple packets
        for i = 1, 10 do
            socket:send("load_packet_" .. i .. "_of_10", sender.ip, sender.port)
        end
        response = "load_test_complete 10_packets_sent"

    elseif data:match("^info") then
        response = string.format("server_info version:%s computer:%d memory:%dKB",
                server.version, os.getComputerID(), math.floor(collectgarbage("count")))

    elseif data:match("^help") then
        response = "commands: ping, time, stats, echo <msg>, load, info, help"

    else
        response = "unknown_command try: help"
    end

    socket:send(response, sender.ip, sender.port)
    server.stats.packets = server.stats.packets + 1
    server.stats.bytes = server.stats.bytes + #response

    if config.log_packets then
        log("DEBUG", "Custom service: %s -> %s (%s:%d)", data, response, sender.ip, sender.port)
    end

    return "Processed: " .. data:sub(1, 20) .. (data:len() > 20 and "..." or "")
end

-- Discovery service
services.discovery = function(socket, data, sender)
    if data:match("^discover") or data:match("^DISCOVER") then
        local discoveryResponse = {
            type = "discovery_response",
            server = "CC-UDP/" .. server.version,
            computer_id = os.getComputerID(),
            services = {
                echo = config.echo_port,
                time = config.time_port,
                custom = config.custom_port,
                discovery = config.discovery_port
            },
            uptime = os.epoch("utc") - server.start_time,
            timestamp = os.epoch("utc")
        }

        local response = textutils.serializeJSON(discoveryResponse)
        socket:send(response, sender.ip, sender.port)

        log("INFO", "Discovery request from %s:%d", sender.ip, sender.port)
        return "Sent discovery response"
    else
        local response = "discovery_service send: discover"
        socket:send(response, sender.ip, sender.port)
        return "Sent discovery help"
    end
end

-- Create and bind sockets
local function createSocket(port, handler, serviceName)
    if not udp then
        log("ERROR", "UDP protocol not available")
        return nil
    end

    local socket = udp.socket(port)
    local success, err = socket:bind(port)

    if not success then
        log("ERROR", "Failed to bind %s service to port %d: %s", serviceName, port, err or "unknown error")
        socket:close()
        return nil
    end

    -- Set up receive callback
    socket:setReceiveCallback(function(data, sender)
        local ok, result = pcall(handler, socket, data, sender)
        if not ok then
            server.stats.errors = server.stats.errors + 1
            log("ERROR", "%s service error: %s", serviceName, result)
        end
    end)

    server.sockets[port] = {
        socket = socket,
        handler = handler,
        service = serviceName,
        created = os.epoch("utc")
    }

    log("INFO", "%s service started on UDP port %d", serviceName, port)
    return socket
end

-- Process received packets manually (for polling mode)
local function processPackets()
    for port, socketInfo in pairs(server.sockets) do
        local socket = socketInfo.socket
        local handler = socketInfo.handler

        -- Non-blocking receive
        local data, sender = socket:receive(0) -- 0 timeout for non-blocking

        while data do
            local ok, result = pcall(handler, socket, data, sender)
            if not ok then
                server.stats.errors = server.stats.errors + 1
                log("ERROR", "%s service error: %s", socketInfo.service, result)
            end

            -- Try to get next packet
            data, sender = socket:receive(0)
        end
    end
end

-- Server management
function server.start()
    if server.running then
        print("UDP server already running")
        return false
    end

    if not udp then
        log("ERROR", "Cannot start UDP server - UDP protocol not available")
        return false
    end

    -- Start UDP service
    udp.start()

    server.running = true
    server.start_time = os.epoch("utc")

    -- Create service sockets
    local services_started = 0

    if createSocket(config.echo_port, services.echo, "Echo") then
        services_started = services_started + 1
    end

    if createSocket(config.time_port, services.time, "Time") then
        services_started = services_started + 1
    end

    if createSocket(config.custom_port, services.custom, "Custom") then
        services_started = services_started + 1
    end

    if createSocket(config.discovery_port, services.discovery, "Discovery") then
        services_started = services_started + 1
    end

    if services_started == 0 then
        log("ERROR", "Failed to start any UDP services")
        server.running = false
        return false
    end

    log("INFO", "UDP server started with %d services", services_started)
    return true
end

function server.stop()
    if not server.running then
        return false
    end

    -- Close all sockets
    for port, socketInfo in pairs(server.sockets) do
        socketInfo.socket:close()
        log("INFO", "Closed %s service on port %d", socketInfo.service, port)
    end

    server.sockets = {}

    -- Stop UDP service
    if udp then
        udp.stop()
    end

    server.running = false
    log("INFO", "UDP server stopped")

    return true
end

function server.getStats()
    local activeServices = 0
    for _, _ in pairs(server.sockets) do
        activeServices = activeServices + 1
    end

    return {
        running = server.running,
        active_services = activeServices,
        packets_processed = server.stats.packets,
        bytes_processed = server.stats.bytes,
        errors = server.stats.errors,
        uptime = server.running and (os.epoch("utc") - server.start_time) or 0,
        services = {
            echo = config.echo_port,
            time = config.time_port,
            custom = config.custom_port,
            discovery = config.discovery_port
        }
    }
end

-- Test client functions
function server.test()
    if not udp then
        print("UDP protocol not available for testing")
        return false
    end

    print("Starting UDP server self-test...")

    -- Create test client socket
    local client = udp.socket()

    -- Test echo service
    print("Testing Echo service...")
    local testData = "UDP Echo Test " .. os.epoch("utc")
    client:send(testData, "127.0.0.1", config.echo_port)
    sleep(0.1)
    local response, sender = client:receive(2)
    if response == testData then
        print("✓ Echo service working")
    else
        print("✗ Echo service failed")
    end

    -- Test time service
    print("Testing Time service...")
    client:send("time_request", "127.0.0.1", config.time_port)
    sleep(0.1)
    local timeResponse, _ = client:receive(2)
    if timeResponse and #timeResponse >= 4 then
        print("✓ Time service working")
    else
        print("✗ Time service failed")
    end

    -- Test custom service commands
    print("Testing Custom service...")
    local commands = {"ping", "time", "stats", "echo hello", "info"}
    for _, cmd in ipairs(commands) do
        client:send(cmd, "127.0.0.1", config.custom_port)
        sleep(0.1)
        local resp, _ = client:receive(1)
        if resp then
            print("✓ Custom command '" .. cmd .. "': " .. resp:sub(1, 50))
        else
            print("✗ Custom command '" .. cmd .. "' failed")
        end
    end

    -- Test discovery service
    print("Testing Discovery service...")
    client:send("discover", "127.0.0.1", config.discovery_port)
    sleep(0.1)
    local discoveryResp, _ = client:receive(2)
    if discoveryResp and discoveryResp:match("discovery_response") then
        print("✓ Discovery service working")
    else
        print("✗ Discovery service failed")
    end

    client:close()

    -- Print final stats
    local stats = server.getStats()
    print("\nUDP Server Test Results:")
    print("  Active services: " .. stats.active_services)
    print("  Packets processed: " .. stats.packets_processed)
    print("  Bytes processed: " .. stats.bytes_processed)
    print("  Errors: " .. stats.errors)

    print("UDP server self-test completed!")
    return true
end

-- Auto-start if run directly
if not _G.udp_test_server then
    _G.udp_test_server = server

    if server.start() then
        print("UDP Test Server started. Press Ctrl+T to stop.")
        print("Services available:")
        print("  Echo: port " .. config.echo_port)
        print("  Time: port " .. config.time_port)
        print("  Custom: port " .. config.custom_port .. " (try: ping, time, stats, echo <msg>, info)")
        print("  Discovery: port " .. config.discovery_port .. " (send: discover)")
        print()
        print("Run server.test() for self-test")

        -- Main server loop
        while server.running do
            local event = os.pullEvent()

            if event == "terminate" then
                server.stop()
                break
            end

            -- Process packets manually if callback mode isn't working
            processPackets()
        end
    else
        print("Failed to start UDP server - check logs")
    end
end

return server