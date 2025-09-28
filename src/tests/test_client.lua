-- /tests/test_client.lua
-- Enhanced Network Test Client with Cross-Computer Communication
-- Supports both local and remote server discovery and testing

local basalt = nil

-- Check for pre-loaded basalt from test_network
if _G._test_network_basalt then
    basalt = _G._test_network_basalt
else
    local success, result = pcall(require, "basalt")
    if success then
        basalt = result
    elseif fs.exists("basalt.lua") then
        success, result = pcall(dofile, "basalt.lua")
        if success then basalt = result end
    end
end

local hasBasalt = basalt ~= nil

local client = {}
client.version = "2.0.0"
client.running = true

-- Load network libraries
local network = nil
local udp = nil

if fs.exists("/lib/network.lua") then
    network = dofile("/lib/network.lua")
end

if fs.exists("/protocols/udp.lua") then
    udp = dofile("/protocols/udp.lua")
elseif _G.netd_udp then
    udp = _G.netd_udp
end

-- Enhanced logging system
local LOG_DIR = "/var/log"
local LOG_FILE = LOG_DIR .. "/test_client.log"
local log_buffer = {}

local function ensureLogDir()
    if not fs.exists(LOG_DIR) then fs.makeDir(LOG_DIR) end
end

local function flushLog()
    ensureLogDir()
    if #log_buffer > 0 then
        local f = fs.open(LOG_FILE, "a")
        if f then
            for _, entry in ipairs(log_buffer) do
                f.writeLine(entry)
            end
            f.close()
        end
        log_buffer = {}
    end
end

-- Logging
local logMessages = {}
local function log(message, level)
    level = level or "INFO"
    local timestamp = os.date("%H:%M:%S")
    local logEntry = string.format("[%s] %s: %s", timestamp, level, message)

    table.insert(logMessages, {
        time = timestamp,
        level = level,
        message = message
    })

    table.insert(log_buffer, os.date("%Y-%m-%d %H:%M:%S") .. " [" .. level .. "] " .. message)

    if #logMessages > 100 then
        table.remove(logMessages, 1)
    end

    if #log_buffer >= 10 then
        flushLog()
    end

    if not hasBasalt then
        print(logEntry)
    end
end

-- Server discovery function
local function discoverServers()
    log("Starting server discovery...")
    local discovered = {}

    -- Open modem if not already open
    local modem = peripheral.find("modem")
    if modem and not rednet.isOpen(peripheral.getName(modem)) then
        rednet.open(peripheral.getName(modem))
    end

    -- Look for HTTP servers
    local httpServers = {rednet.lookup("http_server")}
    for _, id in ipairs(httpServers) do
        if id then
            local hostname = os.getComputerLabel and os.getComputerLabel() or ("cc-" .. id)
            local ip = string.format("10.0.%d.%d",
                    math.floor(id / 254) % 256,
                    (id % 254) + 1)

            table.insert(discovered, {
                type = "http",
                id = id,
                hostname = hostname,
                ip = ip,
                port = 80
            })
            log(string.format("Found HTTP server: %s (ID:%d, IP:%s)", hostname, id, ip))
        end
    end

    -- Look for WebSocket servers
    local wsServers = {rednet.lookup("websocket_server")}
    for _, id in ipairs(wsServers) do
        if id then
            local hostname = "ws-server-" .. id
            local ip = string.format("10.0.%d.%d",
                    math.floor(id / 254) % 256,
                    (id % 254) + 1)

            table.insert(discovered, {
                type = "websocket",
                id = id,
                hostname = hostname,
                ip = ip,
                port = 8081
            })
            log(string.format("Found WebSocket server: %s (ID:%d, IP:%s)", hostname, id, ip))
        end
    end

    -- Broadcast discovery request
    rednet.broadcast({
        type = "server_discovery",
        source = os.getComputerID()
    }, "network_discovery")

    -- Wait for responses
    local timeout = os.startTimer(2)
    while true do
        local event, p1, p2, p3 = os.pullEvent()
        if event == "timer" and p1 == timeout then
            break
        elseif event == "rednet_message" then
            local sender, message, protocol = p1, p2, p3
            if protocol == "network_discovery" and type(message) == "table" then
                if message.type == "server_announce" then
                    table.insert(discovered, {
                        type = message.server_type or "unknown",
                        id = sender,
                        hostname = message.hostname,
                        ip = message.ip,
                        port = message.port
                    })
                    log(string.format("Discovered %s server: %s", message.server_type, message.hostname))
                end
            end
        end
    end

    return discovered
end

-- Test targets with dynamic discovery
local testTargets = {
    http = {
        name = "HTTP Server",
        host = nil,  -- Will be set dynamically
        port = 80,
        computer_id = nil,
        endpoints = {"/", "/test", "/info", "/time", "/echo?msg=test", "/status"}
    },
    websocket = {
        name = "WebSocket Server",
        host = nil,
        port = 8081,
        computer_id = nil,
        connection_id = nil
    },
    udp = {
        name = "UDP Server",
        host = nil,
        computer_id = nil,
        ports = {
            echo = 7,
            time = 37,
            custom = 12345,
            discovery = 1900
        }
    }
}

-- Test results storage
local testResults = {
    http = {},
    websocket = {},
    udp = {}
}

-- Update targets with discovered servers
local function updateTargets(servers)
    for _, server in ipairs(servers) do
        if server.type == "http" and not testTargets.http.host then
            testTargets.http.host = server.ip
            testTargets.http.computer_id = server.id
            log("Set HTTP target to " .. server.ip .. " (ID: " .. server.id .. ")")
        elseif server.type == "websocket" and not testTargets.websocket.host then
            testTargets.websocket.host = server.ip
            testTargets.websocket.computer_id = server.id
            testTargets.websocket.port = server.port
            log("Set WebSocket target to " .. server.ip .. " (ID: " .. server.id .. ")")
        elseif server.type == "udp" and not testTargets.udp.host then
            testTargets.udp.host = server.ip
            testTargets.udp.computer_id = server.id
            log("Set UDP target to " .. server.ip .. " (ID: " .. server.id .. ")")
        end
    end

    -- Fallback to localhost if no servers found
    if not testTargets.http.host then
        testTargets.http.host = "127.0.0.1"
        log("No HTTP servers found, using localhost", "WARN")
    end
    if not testTargets.websocket.host then
        testTargets.websocket.host = "127.0.0.1"
        log("No WebSocket servers found, using localhost", "WARN")
    end
    if not testTargets.udp.host then
        testTargets.udp.host = "127.0.0.1"
        log("No UDP servers found, using localhost", "WARN")
    end
end

-- HTTP Test Functions with cross-computer support
local function testHTTP()
    log("Starting HTTP tests...")
    local results = {}

    -- Ensure we have a target
    if not testTargets.http.host then
        local servers = discoverServers()
        updateTargets(servers)
    end

    for _, endpoint in ipairs(testTargets.http.endpoints) do
        log("Testing HTTP endpoint: " .. endpoint)

        local startTime = os.epoch("utc")
        local success = false
        local response = nil
        local error_msg = nil

        -- If testing remote computer, use rednet
        if testTargets.http.computer_id and testTargets.http.computer_id ~= os.getComputerID() then
            log("Using rednet for remote HTTP to computer " .. testTargets.http.computer_id)

            local request = {
                type = "http_request",
                method = "GET",
                path = endpoint,
                headers = {
                    ["user-agent"] = "CC-TestClient/" .. client.version,
                    ["accept"] = "application/json"
                },
                id = math.random(100000, 999999)
            }

            rednet.send(testTargets.http.computer_id, request, "ccnet_http")

            local timeout = os.startTimer(5)
            while true do
                local event, p1, p2, p3 = os.pullEvent()
                if event == "rednet_message" then
                    local sender, message, protocol = p1, p2, p3
                    if sender == testTargets.http.computer_id and
                            protocol == "ccnet_http" and
                            type(message) == "table" and
                            message.id == request.id then
                        response = message
                        success = true
                        break
                    end
                elseif event == "timer" and p1 == timeout then
                    error_msg = "Request timeout"
                    break
                end
            end
        else
            -- Local or standard HTTP
            local url = string.format("http://%s:%d%s",
                    testTargets.http.host,
                    testTargets.http.port,
                    endpoint)

            log("Using standard HTTP to " .. url)

            local httpResponse = http.get(url, {
                ["user-agent"] = "CC-TestClient/" .. client.version
            })

            if httpResponse then
                response = {
                    code = httpResponse.getResponseCode(),
                    body = httpResponse.readAll(),
                    headers = httpResponse.getResponseHeaders()
                }
                httpResponse.close()
                success = true
            else
                error_msg = "HTTP request failed"
            end
        end

        local endTime = os.epoch("utc")
        local latency = endTime - startTime

        local result = {
            endpoint = endpoint,
            success = success,
            latency = latency,
            status = response and response.code or "N/A",
            error = error_msg or (success and "OK" or "Request failed")
        }

        table.insert(results, result)
        log(string.format("HTTP %s: %s (%.2fms) - %s",
                endpoint,
                result.success and "PASS" or "FAIL",
                latency,
                result.error))
    end

    testResults.http = results
    flushLog()
    return results
end

-- WebSocket Test Functions with cross-computer support
local function testWebSocket()
    log("Starting WebSocket tests...")
    local results = {}

    -- Ensure we have a target
    if not testTargets.websocket.host then
        local servers = discoverServers()
        updateTargets(servers)
    end

    local ws = nil
    local success = false
    local error_msg = nil

    -- For remote WebSocket, use rednet bridge
    if testTargets.websocket.computer_id and testTargets.websocket.computer_id ~= os.getComputerID() then
        log("Using rednet for remote WebSocket to computer " .. testTargets.websocket.computer_id)

        -- Request WebSocket connection via rednet
        local connectRequest = {
            type = "ws_connect",
            source = os.getComputerID()
        }

        rednet.send(testTargets.websocket.computer_id, connectRequest, "websocket")

        local timeout = os.startTimer(5)
        local connectionId = nil

        while true do
            local event, p1, p2, p3 = os.pullEvent()
            if event == "rednet_message" then
                local sender, message, protocol = p1, p2, p3
                if sender == testTargets.websocket.computer_id and
                        protocol == "websocket" and
                        type(message) == "table" and
                        message.type == "ws_connected" then
                    connectionId = message.connectionId
                    success = true
                    break
                end
            elseif event == "timer" and p1 == timeout then
                error_msg = "Connection timeout"
                break
            end
        end

        if success and connectionId then
            testTargets.websocket.connection_id = connectionId

            -- Create WebSocket-like object for rednet
            ws = {
                send = function(data)
                    rednet.send(testTargets.websocket.computer_id, {
                        type = "ws_data",
                        connectionId = connectionId,
                        data = data
                    }, "websocket")
                end,

                receive = function(timeout)
                    local timer = os.startTimer(timeout or 5)
                    while true do
                        local event, p1, p2, p3 = os.pullEvent()
                        if event == "rednet_message" then
                            local sender, message, protocol = p1, p2, p3
                            if sender == testTargets.websocket.computer_id and
                                    protocol == "websocket" and
                                    type(message) == "table" and
                                    message.type == "ws_data" and
                                    message.connectionId == connectionId then
                                os.cancelTimer(timer)
                                return message.data
                            end
                        elseif event == "timer" and p1 == timer then
                            return nil
                        end
                    end
                end,

                close = function()
                    rednet.send(testTargets.websocket.computer_id, {
                        type = "ws_close",
                        connectionId = connectionId
                    }, "websocket")
                end
            }
        end
    else
        -- Local WebSocket
        local wsUrl = string.format("ws://%s:%d",
                testTargets.websocket.host,
                testTargets.websocket.port)

        log("Using standard WebSocket to " .. wsUrl)
        ws = http.websocket(wsUrl)
        success = ws ~= nil
        if not success then
            error_msg = "Failed to connect"
        end
    end

    if success and ws then
        -- Test echo
        local testMessage = "Hello from CC Test Client!"
        ws.send(testMessage)

        local response = ws.receive(2)

        local echoResult = {
            test = "echo",
            success = response == testMessage,
            sent = testMessage,
            received = response or "No response",
            error = response == testMessage and "OK" or "Echo mismatch or timeout"
        }
        table.insert(results, echoResult)
        log(string.format("WebSocket echo: %s", echoResult.success and "PASS" or "FAIL"))

        -- Test ping
        ws.send("ping")
        response = ws.receive(1)

        local pingResult = {
            test = "ping",
            success = response == "pong",
            response = response or "No response",
            error = response == "pong" and "OK" or "Invalid response or timeout"
        }
        table.insert(results, pingResult)
        log(string.format("WebSocket ping: %s", pingResult.success and "PASS" or "FAIL"))

        ws.close()
    else
        local result = {
            test = "connection",
            success = false,
            error = error_msg or "Failed to connect to WebSocket server"
        }
        table.insert(results, result)
        log("WebSocket connection failed: " .. result.error, "ERROR")
    end

    testResults.websocket = results
    flushLog()
    return results
end

-- UDP Test Functions (keeping existing implementation)
local function testUDP()
    if not udp then
        log("UDP protocol not available", "ERROR")
        return {{error = "UDP protocol not available"}}
    end

    log("Starting UDP tests...")
    local results = {}

    -- Ensure we have a target
    if not testTargets.udp.host then
        local servers = discoverServers()
        updateTargets(servers)
    end

    -- Create UDP socket
    local testSocket = udp.socket()
    if not testSocket then
        log("Failed to create UDP socket", "ERROR")
        return {{error = "Failed to create UDP socket"}}
    end

    -- Test Echo service
    log("Testing UDP Echo service...")
    local testData = "Echo test from CC"
    local success = testSocket:send(testData, testTargets.udp.host, testTargets.udp.ports.echo)

    if success then
        local response, sender = testSocket:receive(2)
        local result = {
            service = "echo",
            success = response == testData,
            sent = testData,
            received = response or "No response",
            error = response == testData and "OK" or "Echo mismatch or timeout"
        }
        table.insert(results, result)
        log(string.format("UDP Echo: %s", result.success and "PASS" or "FAIL"))
    end

    -- Test other services...
    testSocket:close()
    testResults.udp = results
    flushLog()
    return results
end

-- Run all tests
function client.runAllTests()
    log("Starting comprehensive network tests")

    -- Discover servers first
    local servers = discoverServers()
    log(string.format("Discovered %d servers", #servers))
    updateTargets(servers)

    testResults = {
        http = {},
        websocket = {},
        udp = {}
    }

    testHTTP()
    testWebSocket()
    testUDP()

    log("All tests completed")
    flushLog()
    return testResults
end

-- Console menu and GUI creation remain similar but with server discovery option
local function consoleMenu()
    while client.running do
        term.clear()
        term.setCursorPos(1, 1)
        print("=== CC Network Test Client v" .. client.version .. " ===")
        print("")
        print("Select test to run:")
        print("1. Discover Servers")
        print("2. Test HTTP Server")
        print("3. Test WebSocket Server")
        print("4. Test UDP Server")
        print("5. Run All Tests")
        print("6. Show Last Results")
        print("7. View Logs")
        print("Q. Quit")
        print("")
        write("Choice: ")

        local choice = string.upper(read())

        if choice == "Q" then
            client.running = false
        elseif choice == "1" then
            print("\nDiscovering servers...")
            local servers = discoverServers()
            print(string.format("\nFound %d servers:", #servers))
            for _, server in ipairs(servers) do
                print(string.format("  %s server at %s (ID:%d, Port:%d)",
                        server.type, server.ip, server.id, server.port))
            end
            updateTargets(servers)
            print("\nPress any key to continue...")
            os.pullEvent("key")
        elseif choice == "2" then
            print("\nRunning HTTP tests...")
            testHTTP()
            print("\nResults:")
            for _, result in ipairs(testResults.http) do
                print(string.format("  %s: %s",
                        result.endpoint or "test",
                        result.success and "PASS" or "FAIL"))
            end
            print("\nPress any key to continue...")
            os.pullEvent("key")
        elseif choice == "3" then
            print("\nRunning WebSocket tests...")
            testWebSocket()
            print("\nResults:")
            for _, result in ipairs(testResults.websocket) do
                print(string.format("  %s: %s",
                        result.test or "test",
                        result.success and "PASS" or "FAIL"))
            end
            print("\nPress any key to continue...")
            os.pullEvent("key")
        elseif choice == "4" then
            print("\nRunning UDP tests...")
            testUDP()
            print("\nResults:")
            for _, result in ipairs(testResults.udp) do
                print(string.format("  %s: %s",
                        result.service or "test",
                        result.success and "PASS" or "FAIL"))
            end
            print("\nPress any key to continue...")
            os.pullEvent("key")
        elseif choice == "5" then
            print("\nRunning all tests...")
            client.runAllTests()
            print("\nResults Summary:")
            for protocol, results in pairs(testResults) do
                local passed = 0
                local total = #results
                for _, result in ipairs(results) do
                    if result.success then passed = passed + 1 end
                end
                print(string.format("  %s: %d/%d passed",
                        protocol:upper(), passed, total))
            end
            print("\nPress any key to continue...")
            os.pullEvent("key")
        elseif choice == "6" then
            print("\nLast Test Results:")
            for protocol, results in pairs(testResults) do
                if #results > 0 then
                    print(string.format("\n%s:", protocol:upper()))
                    for _, result in ipairs(results) do
                        local name = result.endpoint or result.test or result.service or "test"
                        print(string.format("  %s: %s", name,
                                result.success and "PASS" or "FAIL"))
                    end
                end
            end
            print("\nPress any key to continue...")
            os.pullEvent("key")
        elseif choice == "7" then
            print("\nViewing logs...")
            if fs.exists(LOG_FILE) then
                shell.run("edit", LOG_FILE)
            else
                print("No log file found.")
                print("\nPress any key to continue...")
                os.pullEvent("key")
            end
        end
    end
end

-- Main entry point
local function main()
    log("Network Test Client v" .. client.version .. " starting...")

    -- Open modem for rednet communication
    local modem = peripheral.find("modem")
    if modem then
        local side = peripheral.getName(modem)
        if not rednet.isOpen(side) then
            rednet.open(side)
            log("Opened modem on side: " .. side)
        end
    else
        log("No modem found - remote server testing unavailable", "WARN")
    end

    if hasBasalt then
        -- GUI mode would go here
        log("Running in console mode (GUI not implemented)")
        consoleMenu()
    else
        log("Running in console mode")
        consoleMenu()
    end

    flushLog()
    term.clear()
    term.setCursorPos(1, 1)
    print("Test Client exited.")
    print("Logs saved to: " .. LOG_FILE)
end

-- Check if being loaded by test_network or run directly
if not (_G.network_test_client or _G._test_network_basalt) then
    -- Running directly
    main()
else
    -- Being loaded as a module
    _G.network_test_client = client
end

return client