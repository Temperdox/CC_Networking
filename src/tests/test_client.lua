-- /tests/test_client.lua
-- Network Test Client for ComputerCraft Network System
-- Fixed version that works with bridge loader

local basalt = nil

-- Check for pre-loaded basalt from test_network
if _G._test_network_basalt then
    basalt = _G._test_network_basalt
else
    -- Try to load basalt normally
    local success, result = pcall(require, "basalt")
    if success then
        basalt = result
    else
        -- Fallback - try direct load
        if fs.exists("basalt.lua") then
            success, result = pcall(dofile, "basalt.lua")
            if success then
                basalt = result
            end
        end
    end
end

local hasBasalt = basalt ~= nil

local client = {}
client.version = "1.0.0"
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

-- Test targets
local testTargets = {
    http = {
        name = "HTTP Server",
        host = "127.0.0.1",
        port = 8080,
        endpoints = {"/", "/api/status", "/api/time", "/api/computer", "/api/test"}
    },
    websocket = {
        name = "WebSocket Server",
        host = "127.0.0.1",
        port = 8081,
        connection_id = nil
    },
    udp = {
        name = "UDP Server",
        host = "127.0.0.1",
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

    -- Keep log size manageable
    if #logMessages > 100 then
        table.remove(logMessages, 1)
    end

    if not hasBasalt then
        print(logEntry)
    end
end

-- HTTP Test Functions
local function testHTTP()
    log("Starting HTTP tests...")
    local results = {}

    for _, endpoint in ipairs(testTargets.http.endpoints) do
        log("Testing HTTP endpoint: " .. endpoint)

        local request = {
            method = "GET",
            path = endpoint,
            headers = {
                ["user-agent"] = "CC-TestClient/" .. client.version,
                ["accept"] = "application/json"
            }
        }

        local startTime = os.epoch("utc")
        local success = false
        local response = nil

        -- Try using network library first
        if network and network.http_request then
            success, response = pcall(network.http_request,
                    testTargets.http.host,
                    testTargets.http.port,
                    request)
        else
            -- Fallback to standard http API
            local url = string.format("http://%s:%d%s",
                    testTargets.http.host,
                    testTargets.http.port,
                    endpoint)

            local httpResponse = http.get(url, request.headers)
            if httpResponse then
                response = {
                    status = httpResponse.getResponseCode(),
                    body = httpResponse.readAll(),
                    headers = httpResponse.getResponseHeaders()
                }
                httpResponse.close()
                success = true
            end
        end

        local endTime = os.epoch("utc")
        local latency = endTime - startTime

        local result = {
            endpoint = endpoint,
            success = success,
            latency = latency,
            status = response and response.status or "N/A",
            error = success and "OK" or "Request failed"
        }

        table.insert(results, result)
        log(string.format("HTTP %s: %s (%.2fms)",
                endpoint,
                result.success and "PASS" or "FAIL",
                latency))
    end

    testResults.http = results
    return results
end

-- WebSocket Test Functions
local function testWebSocket()
    log("Starting WebSocket tests...")
    local results = {}

    -- WebSocket connection test
    local wsUrl = string.format("ws://%s:%d",
            testTargets.websocket.host,
            testTargets.websocket.port)

    log("Connecting to WebSocket server...")
    local ws = nil
    local success = false

    if network and network.websocket_connect then
        success, ws = pcall(network.websocket_connect, wsUrl)
    else
        -- Fallback to standard websocket API
        ws = http.websocket(wsUrl)
        success = ws ~= nil
    end

    if success and ws then
        testTargets.websocket.connection_id = ws

        -- Test echo
        local testMessage = "Hello from CC Test Client!"
        ws.send(testMessage)

        local response = nil
        local timeout = os.startTimer(2)

        while true do
            local event, param1, param2 = os.pullEvent()
            if event == "websocket_message" and param1 == ws then
                response = param2
                break
            elseif event == "timer" and param1 == timeout then
                break
            end
        end

        local echoResult = {
            test = "echo",
            success = response == testMessage,
            sent = testMessage,
            received = response or "No response",
            error = response == testMessage and "OK" or "Echo mismatch or timeout"
        }
        table.insert(results, echoResult)

        -- Test ping
        ws.send("ping")
        response = nil
        timeout = os.startTimer(1)

        while true do
            local event, param1, param2 = os.pullEvent()
            if event == "websocket_message" and param1 == ws then
                response = param2
                break
            elseif event == "timer" and param1 == timeout then
                break
            end
        end

        local pingResult = {
            test = "ping",
            success = response == "pong",
            response = response or "No response",
            error = response == "pong" and "OK" or "Invalid response or timeout"
        }
        table.insert(results, pingResult)

        ws.close()
    else
        local result = {
            test = "connection",
            success = false,
            error = "Failed to connect to WebSocket server"
        }
        table.insert(results, result)
    end

    testResults.websocket = results
    return results
end

-- UDP Test Functions
local function testUDP()
    if not udp then
        log("UDP protocol not available", "ERROR")
        return {{error = "UDP protocol not available"}}
    end

    log("Starting UDP tests...")
    local results = {}

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
        local response, sender = testSocket:receive(2) -- 2 second timeout
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

    -- Test Time service
    log("Testing UDP Time service...")
    success = testSocket:send("time", testTargets.udp.host, testTargets.udp.ports.time)
    if success then
        local response, sender = testSocket:receive(2)
        local result = {
            service = "time",
            success = response ~= nil,
            response = response or "No response",
            error = response and "OK" or "Timeout"
        }
        table.insert(results, result)
        log(string.format("UDP Time: %s", result.success and "PASS" or "FAIL"))
    end

    -- Test Custom service
    log("Testing UDP Custom service...")
    local commands = {"status", "info", "test"}
    for _, command in ipairs(commands) do
        success = testSocket:send(command, testTargets.udp.host, testTargets.udp.ports.custom)
        if success then
            local response, sender = testSocket:receive(2)
            local result = {
                service = "custom",
                command = command,
                success = response ~= nil,
                response = response or "No response",
                error = response and "OK" or "Timeout"
            }
            table.insert(results, result)
            log(string.format("UDP Custom '%s': %s", command, result.success and "PASS" or "FAIL"))
        end
    end

    -- Test Discovery service
    log("Testing UDP Discovery service...")
    success = testSocket:send("discover", testTargets.udp.host, testTargets.udp.ports.discovery)
    if success then
        local response, sender = testSocket:receive(2)
        local result = {
            service = "discovery",
            success = response ~= nil and response:match("discovery_response"),
            response = response or "No response",
            error = response and (response:match("discovery_response") and "OK" or "Invalid response") or "No response"
        }
        table.insert(results, result)
        log("UDP Discovery: " .. (result.success and "PASS" or "FAIL"))
    end

    testSocket:close()
    testResults.udp = results
    return results
end

-- Run all tests
function client.runAllTests()
    testResults = {
        http = {},
        websocket = {},
        udp = {}
    }

    testHTTP()
    testWebSocket()
    testUDP()

    return testResults
end

-- GUI Creation (only if Basalt available)
local main, statusLabel, resultsList

local function createTestUI()
    if not hasBasalt then
        log("Basalt not available - running in console mode", "INFO")
        return false
    end

    local w, h = term.getSize()
    main = basalt.getMainFrame():setBackground(colors.blue):setSize(w, h)

    -- Title
    main:addLabel():setPosition(1, 1):setSize(w, 1)
        :setText("CC Network Test Client v" .. client.version)
        :setForeground(colors.white):setBackground(colors.blue)

    -- Status panel
    local statusPanel = main:addFrame():setPosition(2, 3):setSize(w-2, 6):setBackground(colors.white)
    statusPanel:addLabel():setPosition(1, 1):setText("Network Test Client"):setForeground(colors.black)

    statusLabel = statusPanel:addLabel():setPosition(1, 2):setText("Ready to test")
                             :setForeground(colors.gray)

    -- Test buttons
    local httpBtn = statusPanel:addButton():setPosition(2, 4):setSize(12, 1)
                               :setText("Test HTTP"):setBackground(colors.orange):setForeground(colors.white)

    local wsBtn = statusPanel:addButton():setPosition(15, 4):setSize(12, 1)
                             :setText("Test WS"):setBackground(colors.purple):setForeground(colors.white)

    local udpBtn = statusPanel:addButton():setPosition(28, 4):setSize(12, 1)
                              :setText("Test UDP"):setBackground(colors.cyan):setForeground(colors.black)

    local allBtn = statusPanel:addButton():setPosition(41, 4):setSize(10, 1)
                              :setText("Test All"):setBackground(colors.green):setForeground(colors.white)

    -- Results panel
    local resultsPanel = main:addFrame():setPosition(2, 10):setSize(w-2, h-11):setBackground(colors.black)
    resultsPanel:addLabel():setPosition(1, 1):setText("Test Results"):setForeground(colors.white)

    resultsList = resultsPanel:addList():setPosition(1, 2):setSize(w-2, h-13)
                              :setBackground(colors.black):setForeground(colors.white)

    -- Button handlers
    httpBtn:onClick(function()
        statusLabel:setText("Running HTTP tests..."):setForeground(colors.orange)
        resultsList:clear()
        local results = testHTTP()
        for _, result in ipairs(results) do
            local color = result.success and colors.green or colors.red
            resultsList:addItem(string.format("HTTP %s: %s", result.endpoint or "test",
                    result.success and "PASS" or "FAIL")):setForeground(color)
        end
        statusLabel:setText("HTTP tests complete"):setForeground(colors.green)
    end)

    wsBtn:onClick(function()
        statusLabel:setText("Running WebSocket tests..."):setForeground(colors.purple)
        resultsList:clear()
        local results = testWebSocket()
        for _, result in ipairs(results) do
            local color = result.success and colors.green or colors.red
            resultsList:addItem(string.format("WS %s: %s", result.test or "test",
                    result.success and "PASS" or "FAIL")):setForeground(color)
        end
        statusLabel:setText("WebSocket tests complete"):setForeground(colors.green)
    end)

    udpBtn:onClick(function()
        statusLabel:setText("Running UDP tests..."):setForeground(colors.cyan)
        resultsList:clear()
        local results = testUDP()
        for _, result in ipairs(results) do
            local color = result.success and colors.green or colors.red
            resultsList:addItem(string.format("UDP %s: %s", result.service or "test",
                    result.success and "PASS" or "FAIL")):setForeground(color)
        end
        statusLabel:setText("UDP tests complete"):setForeground(colors.green)
    end)

    allBtn:onClick(function()
        statusLabel:setText("Running all tests..."):setForeground(colors.yellow)
        resultsList:clear()

        client.runAllTests()

        for protocol, results in pairs(testResults) do
            resultsList:addItem(string.format("=== %s ===", protocol:upper())):setForeground(colors.yellow)
            for _, result in ipairs(results) do
                local color = result.success and colors.green or colors.red
                local name = result.endpoint or result.test or result.service or "test"
                resultsList:addItem(string.format("  %s: %s", name,
                        result.success and "PASS" or "FAIL")):setForeground(color)
            end
        end

        statusLabel:setText("All tests complete"):setForeground(colors.green)
    end)

    -- Exit button
    local exitBtn = main:addButton():setPosition(w-8, h):setSize(8, 1)
                        :setText("Exit"):setBackground(colors.red):setForeground(colors.white)

    exitBtn:onClick(function()
        client.running = false
    end)

    return true
end

-- Console mode functions
local function consoleMenu()
    while client.running do
        term.clear()
        term.setCursorPos(1, 1)
        print("=== CC Network Test Client ===")
        print("")
        print("Select test to run:")
        print("1. Test HTTP Server")
        print("2. Test WebSocket Server")
        print("3. Test UDP Server")
        print("4. Run All Tests")
        print("5. Show Last Results")
        print("Q. Quit")
        print("")
        write("Choice: ")

        local choice = string.upper(read())

        if choice == "Q" then
            client.running = false
        elseif choice == "1" then
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
        elseif choice == "2" then
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
        elseif choice == "3" then
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
        elseif choice == "4" then
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
        elseif choice == "5" then
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
        end
    end
end

-- Main entry point
local function main()
    log("Network Test Client v" .. client.version .. " starting...")

    if hasBasalt then
        if createTestUI() then
            log("GUI initialized with Basalt")
            while client.running do
                local event = {os.pullEventRaw()}
                basalt.update(table.unpack(event))

                if event[1] == "terminate" then
                    client.running = false
                end
            end
        else
            log("Failed to create GUI, falling back to console mode")
            consoleMenu()
        end
    else
        log("Running in console mode")
        consoleMenu()
    end

    term.clear()
    term.setCursorPos(1, 1)
    print("Test Client exited.")
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