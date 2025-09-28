-- /tests/test_client.lua
-- Network Test Client for ComputerCraft Network System
-- Tests HTTP, WebSocket, and UDP servers with Basalt UI rendering

local basalt = require("basalt")

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
local function log(message, level)
    level = level or "INFO"
    local timestamp = os.date("%H:%M:%S")
    local logEntry = string.format("[%s] %s: %s", timestamp, level, message)
    print(logEntry)
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
                ["accept"] = "application/xml"
            },
            source = os.getComputerID()
        }

        -- Send via rednet (simulating HTTP over the network layer)
        local response = nil
        if rednet.isOpen() then
            rednet.broadcast({
                type = "http_request",
                method = request.method,
                path = request.path,
                headers = request.headers,
                port = testTargets.http.port,
                timestamp = os.epoch("utc")
            }, "network_packet")

            -- Wait for response
            local timer = os.startTimer(5)
            while true do
                local event, p1, p2, p3 = os.pullEvent()
                if event == "rednet_message" and p3 == "network_packet" then
                    if p2.type == "http_response" then
                        response = p2
                        os.cancelTimer(timer)
                        break
                    end
                elseif event == "timer" and p1 == timer then
                    break
                end
            end
        end

        local result = {
            endpoint = endpoint,
            success = response ~= nil,
            status_code = response and response.code or 0,
            response_time = 0, -- Would need timing
            content_type = response and response.headers and response.headers["content-type"] or "unknown",
            body_size = response and response.body and #response.body or 0,
            error = response and "OK" or "No response"
        }

        table.insert(results, result)

        local status = result.success and "PASS" or "FAIL"
        log(string.format("HTTP %s %s: %s (code: %d)", endpoint, status, result.error, result.status_code))
    end

    testResults.http = results
    return results
end

-- WebSocket Test Functions
local function testWebSocket()
    log("Starting WebSocket tests...")
    local results = {}

    if not rednet.isOpen() then
        log("Cannot test WebSocket - rednet not available", "ERROR")
        return {error = "Network not available"}
    end

    -- Connect to WebSocket server
    local connectionRequest = {
        type = "ws_connect",
        url = "ws://" .. testTargets.websocket.host .. ":" .. testTargets.websocket.port,
        connectionId = "test_" .. os.getComputerID() .. "_" .. os.epoch("utc"),
        timestamp = os.epoch("utc")
    }

    rednet.broadcast(connectionRequest, "websocket")

    -- Wait for connection acceptance
    local connected = false
    local timer = os.startTimer(5)

    while not connected do
        local event, sender, message, protocol = os.pullEvent()

        if event == "rednet_message" and protocol == "websocket" then
            if message.type == "ws_accept" and message.connectionId == connectionRequest.connectionId then
                connected = true
                testTargets.websocket.connection_id = message.connectionId
                os.cancelTimer(timer)
                log("WebSocket connected: " .. message.connectionId)
                break
            elseif message.type == "ws_reject" then
                log("WebSocket connection rejected: " .. (message.reason or "unknown"), "ERROR")
                break
            end
        elseif event == "timer" and sender == timer then
            log("WebSocket connection timeout", "ERROR")
            break
        end
    end

    if not connected then
        testResults.websocket = {error = "Connection failed"}
        return testResults.websocket
    end

    -- Test various WebSocket commands
    local commands = {"/ping", "/status", "/help", "/time", "Hello WebSocket!"}

    for _, command in ipairs(commands) do
        log("Testing WebSocket command: " .. command)

        local dataPacket = {
            type = "ws_data",
            connectionId = testTargets.websocket.connection_id,
            data = command,
            timestamp = os.epoch("utc")
        }

        rednet.broadcast(dataPacket, "websocket")

        -- Wait for response
        local timer = os.startTimer(3)
        local response = nil

        while not response do
            local event, sender, message, protocol = os.pullEvent()

            if event == "rednet_message" and protocol == "websocket" then
                if message.type == "ws_data" and message.connectionId == testTargets.websocket.connection_id then
                    response = message.data
                    os.cancelTimer(timer)
                    break
                end
            elseif event == "timer" and sender == timer then
                break
            end
        end

        local result = {
            command = command,
            success = response ~= nil,
            response = response or "No response",
            response_size = response and #response or 0
        }

        table.insert(results, result)

        local status = result.success and "PASS" or "FAIL"
        log(string.format("WebSocket '%s' %s: %s", command, status, string.sub(result.response, 1, 50)))
    end

    -- Close connection
    local closePacket = {
        type = "ws_close",
        connectionId = testTargets.websocket.connection_id,
        reason = "Test completed"
    }
    rednet.broadcast(closePacket, "websocket")

    testResults.websocket = results
    return results
end

-- UDP Test Functions
local function testUDP()
    log("Starting UDP tests...")
    local results = {}

    if not udp then
        log("Cannot test UDP - UDP protocol not available", "ERROR")
        testResults.udp = {error = "UDP protocol not available"}
        return testResults.udp
    end

    -- Start UDP if not running
    if not udp.isRunning or not udp.isRunning() then
        udp.start()
    end

    -- Create test socket
    local testSocket = udp.socket()

    -- Test Echo service
    log("Testing UDP Echo service...")
    local echoData = "UDP Echo Test " .. os.epoch("utc")
    local success = testSocket:send(echoData, testTargets.udp.host, testTargets.udp.ports.echo)

    if success then
        local response, sender = testSocket:receive(2)
        local result = {
            service = "echo",
            success = response == echoData,
            sent = echoData,
            received = response or "No response",
            error = response == echoData and "OK" or "Echo mismatch"
        }
        table.insert(results, result)
        log("UDP Echo: " .. (result.success and "PASS" or "FAIL"))
    else
        table.insert(results, {service = "echo", success = false, error = "Send failed"})
        log("UDP Echo: FAIL - Send failed")
    end

    -- Test Time service
    log("Testing UDP Time service...")
    success = testSocket:send("time_request", testTargets.udp.host, testTargets.udp.ports.time)
    if success then
        local response, sender = testSocket:receive(2)
        local result = {
            service = "time",
            success = response ~= nil,
            response_size = response and #response or 0,
            error = response and "OK" or "No response"
        }
        table.insert(results, result)
        log("UDP Time: " .. (result.success and "PASS" or "FAIL"))
    end

    -- Test Custom service commands
    local customCommands = {"ping", "time", "stats", "echo test123", "info", "help"}

    for _, command in ipairs(customCommands) do
        log("Testing UDP Custom command: " .. command)
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

-- UI Creation
local main, statusLabel, resultsList

local function createTestUI()
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
                               :setText("Test HTTP"):setBackground(colors.green):setForeground(colors.white)

    local wsBtn = statusPanel:addButton():setPosition(15, 4):setSize(12, 1)
                             :setText("Test WebSocket"):setBackground(colors.orange):setForeground(colors.white)

    local udpBtn = statusPanel:addButton():setPosition(28, 4):setSize(12, 1)
                              :setText("Test UDP"):setBackground(colors.cyan):setForeground(colors.white)

    local allBtn = statusPanel:addButton():setPosition(41, 4):setSize(8, 1)
                              :setText("Test All"):setBackground(colors.purple):setForeground(colors.white)

    -- Results panel
    local resultsPanel = main:addFrame():setPosition(2, 10):setSize(w-2, h-10):setBackground(colors.black)
    resultsPanel:addLabel():setPosition(1, 1):setText("Test Results"):setForeground(colors.white)

    resultsList = resultsPanel:addList():setPosition(1, 2):setSize(w-2, h-12)
                              :setBackground(colors.black):setForeground(colors.white)

    -- Button handlers
    httpBtn:onClick(function()
        statusLabel:setText("Running HTTP tests...")
        local results = testHTTP()

        resultsList:clear()
        resultsList:addItem("=== HTTP Test Results ===", colors.yellow)
        for _, result in ipairs(results) do
            local color = result.success and colors.green or colors.red
            local status = result.success and "PASS" or "FAIL"
            resultsList:addItem(string.format("%s: %s (%d)", result.endpoint, status, result.status_code), color)
        end

        statusLabel:setText("HTTP tests completed")
    end)

    wsBtn:onClick(function()
        statusLabel:setText("Running WebSocket tests...")
        local results = testWebSocket()

        resultsList:clear()
        if results.error then
            resultsList:addItem("=== WebSocket Test Results ===", colors.yellow)
            resultsList:addItem("ERROR: " .. results.error, colors.red)
        else
            resultsList:addItem("=== WebSocket Test Results ===", colors.yellow)
            for _, result in ipairs(results) do
                local color = result.success and colors.green or colors.red
                local status = result.success and "PASS" or "FAIL"
                resultsList:addItem(string.format("%s: %s", result.command, status), color)
            end
        end

        statusLabel:setText("WebSocket tests completed")
    end)

    udpBtn:onClick(function()
        statusLabel:setText("Running UDP tests...")
        local results = testUDP()

        resultsList:clear()
        if results.error then
            resultsList:addItem("=== UDP Test Results ===", colors.yellow)
            resultsList:addItem("ERROR: " .. results.error, colors.red)
        else
            resultsList:addItem("=== UDP Test Results ===", colors.yellow)
            for _, result in ipairs(results) do
                local color = result.success and colors.green or colors.red
                local status = result.success and "PASS" or "FAIL"
                local desc = result.command or result.service
                resultsList:addItem(string.format("%s: %s", desc, status), color)
            end
        end

        statusLabel:setText("UDP tests completed")
    end)

    allBtn:onClick(function()
        statusLabel:setText("Running all tests...")
        resultsList:clear()

        -- Run all tests
        local httpResults = testHTTP()
        local wsResults = testWebSocket()
        local udpResults = testUDP()

        -- Display consolidated results
        resultsList:addItem("=== Complete Test Results ===", colors.yellow)

        -- HTTP Results
        resultsList:addItem("HTTP Tests:", colors.cyan)
        for _, result in ipairs(httpResults) do
            local color = result.success and colors.green or colors.red
            local status = result.success and "PASS" or "FAIL"
            resultsList:addItem("  " .. result.endpoint .. ": " .. status, color)
        end

        -- WebSocket Results
        resultsList:addItem("WebSocket Tests:", colors.cyan)
        if wsResults.error then
            resultsList:addItem("  ERROR: " .. wsResults.error, colors.red)
        else
            for _, result in ipairs(wsResults) do
                local color = result.success and colors.green or colors.red
                local status = result.success and "PASS" or "FAIL"
                resultsList:addItem("  " .. result.command .. ": " .. status, color)
            end
        end

        -- UDP Results
        resultsList:addItem("UDP Tests:", colors.cyan)
        if udpResults.error then
            resultsList:addItem("  ERROR: " .. udpResults.error, colors.red)
        else
            for _, result in ipairs(udpResults) do
                local color = result.success and colors.green or colors.red
                local status = result.success and "PASS" or "FAIL"
                local desc = result.command or result.service
                resultsList:addItem("  " .. desc .. ": " .. status, color)
            end
        end

        statusLabel:setText("All tests completed")
    end)

    -- Exit button
    local exitBtn = main:addButton():setPosition(w-8, h):setSize(8, 1)
                        :setText("Exit"):setBackground(colors.red):setForeground(colors.white)

    exitBtn:onClick(function()
        client.running = false
    end)
end

-- Main execution
local function main_loop()
    createTestUI()

    -- Initial status
    local networkStatus = rednet.isOpen() and "Network: OK" or "Network: Offline"
    local udpStatus = (udp and "UDP: Available") or "UDP: Not Available"
    statusLabel:setText(networkStatus .. " | " .. udpStatus)

    while client.running do
        local event = {os.pullEventRaw()}
        basalt.update(table.unpack(event))

        if event[1] == "terminate" then
            client.running = false
        end
    end

    -- Clean exit
    term.clear()
    term.setCursorPos(1, 1)
    print("Network Test Client exited.")
end

-- Export functions
client.testHTTP = testHTTP
client.testWebSocket = testWebSocket
client.testUDP = testUDP
client.testResults = testResults

-- Auto-start UI if run directly
if not _G.network_test_client then
    _G.network_test_client = client
    main_loop()
end

return client