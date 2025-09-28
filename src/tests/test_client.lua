-- /tests/test_client.lua
-- Network Test Client for ComputerCraft Network System
-- Tests HTTP, WebSocket, and UDP servers with Basalt UI rendering

-- ---- safeRequire: works with/without global `require`
local function safeRequire(name)
    if type(require) == "function" then
        local ok, mod = pcall(require, name)
        if ok and mod ~= nil then return mod end
    end
    local candidates = {
        "/" .. name .. ".lua",
        name .. ".lua",
    }
    for _, p in ipairs(candidates) do
        if fs.exists(p) then
            local ok, mod = pcall(dofile, p)
            if ok and mod ~= nil then return mod end
        end
    end
    error("safeRequire: cannot load module '" .. tostring(name) .. "'")
end

local basalt = safeRequire("basalt")

local client = {}
client.version = "1.0.0"
client.running = true

-- Load network libraries
local network = nil
local udp = nil

if fs.exists("/lib/network.lua") then
    local ok, mod = pcall(dofile, "/lib/network.lua")
    if ok then network = mod end
end

if fs.exists("/protocols/udp.lua") then
    local ok, mod = pcall(dofile, "/protocols/udp.lua")
    if ok then udp = mod end
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
local testResults = { http = {}, websocket = {}, udp = {} }

-- Logging
local function log(message, level)
    level = level or "INFO"
    local timestamp = os.date("%H:%M:%S")
    local logEntry = string.format("[%s] %s: %s", timestamp, level, message)
    print(logEntry)
end

-- HTTP tests (rednet-simulated for now)
local function testHTTP()
    log("Starting HTTP tests...")
    local results = {}

    for _, endpoint in ipairs(testTargets.http.endpoints) do
        log("Testing HTTP endpoint: " .. endpoint)

        local response = nil
        if rednet.isOpen() then
            rednet.broadcast({
                type = "http_request",
                method = "GET",
                path = endpoint,
                headers = { ["user-agent"]="CC-TestClient/"..client.version, ["accept"]="application/xml" },
                port = testTargets.http.port,
                timestamp = os.epoch("utc")
            }, "network_packet")

            local timer = os.startTimer(5)
            while true do
                local event, p1, p2, p3 = os.pullEvent()
                if event == "rednet_message" and p3 == "network_packet" then
                    if type(p2) == "table" and p2.type == "http_response" then
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
            response_time = 0,
            content_type = response and response.headers and response.headers["content-type"] or "unknown",
            body_size = response and response.body and #response.body or 0,
            error = response and "OK" or "No response"
        }
        table.insert(results, result)
        log(string.format("HTTP %s %s: %s (code: %d)", endpoint, result.success and "PASS" or "FAIL", result.error, result.status_code))
    end

    testResults.http = results
    return results
end

local function testWebSocket()
    log("Starting WebSocket tests...")
    local results = {}

    if not rednet.isOpen() then
        log("Cannot test WebSocket - rednet not available", "ERROR")
        testResults.websocket = { error = "Network not available" }
        return testResults.websocket
    end

    local connectionRequest = {
        type = "ws_connect",
        url = "ws://" .. testTargets.websocket.host .. ":" .. testTargets.websocket.port,
        connectionId = "test_" .. os.getComputerID() .. "_" .. os.epoch("utc"),
        timestamp = os.epoch("utc")
    }
    rednet.broadcast(connectionRequest, "websocket")

    local connected = false
    local timer = os.startTimer(5)
    while not connected do
        local event, sender, message, protocol = os.pullEvent()
        if event == "rednet_message" and protocol == "websocket" then
            if type(message) == "table" and message.type == "ws_accept" and message.connectionId == connectionRequest.connectionId then
                connected = true
                testTargets.websocket.connection_id = message.connectionId
                os.cancelTimer(timer)
                log("WebSocket connected: " .. message.connectionId)
                break
            elseif type(message) == "table" and message.type == "ws_reject" then
                log("WebSocket connection rejected: " .. (message.reason or "unknown"), "ERROR")
                break
            end
        elseif event == "timer" and sender == timer then
            log("WebSocket connection timeout", "ERROR")
            break
        end
    end

    if not connected then
        testResults.websocket = { error = "Connection failed" }
        return testResults.websocket
    end

    local commands = {"/ping", "/status", "/help", "/time", "Hello WebSocket!"}
    for _, command in ipairs(commands) do
        log("Testing WebSocket command: " .. command)

        rednet.broadcast({
            type = "ws_data",
            connectionId = testTargets.websocket.connection_id,
            data = command,
            timestamp = os.epoch("utc")
        }, "websocket")

        local timer2 = os.startTimer(3)
        local response = nil
        while not response do
            local event, sender, message, protocol = os.pullEvent()
            if event == "rednet_message" and protocol == "websocket" then
                if type(message) == "table" and message.type == "ws_data" and message.connectionId == testTargets.websocket.connection_id then
                    response = message.data
                    os.cancelTimer(timer2)
                    break
                end
            elseif event == "timer" and sender == timer2 then
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
        log(string.format("WebSocket '%s' %s: %s", command, result.success and "PASS" or "FAIL", tostring(response or "")):sub(1, 120))
    end

    rednet.broadcast({ type="ws_close", connectionId=testTargets.websocket.connection_id, reason="Test completed" }, "websocket")
    testResults.websocket = results
    return results
end

local function testUDP()
    log("Starting UDP tests...")
    local results = {}

    if not udp then
        log("Cannot test UDP - UDP protocol not available", "ERROR")
        testResults.udp = { error = "UDP protocol not available" }
        return testResults.udp
    end

    if not (udp.isRunning and udp.isRunning()) then
        udp.start()
    end

    local testSocket = udp.socket()

    -- Echo
    local echoData = "UDP Echo Test " .. os.epoch("utc")
    local success = testSocket:send(echoData, testTargets.udp.host, testTargets.udp.ports.echo)
    if success then
        local response = select(1, testSocket:receive(2))
        table.insert(results, { service="echo", success=response==echoData, sent=echoData, received=response or "No response",
                                error=(response==echoData) and "OK" or "Echo mismatch" })
        log("UDP Echo: " .. ((response==echoData) and "PASS" or "FAIL"))
    else
        table.insert(results, { service="echo", success=false, error="Send failed" })
        log("UDP Echo: FAIL - Send failed")
    end

    -- Time
    success = testSocket:send("time_request", testTargets.udp.host, testTargets.udp.ports.time)
    if success then
        local response = select(1, testSocket:receive(2))
        table.insert(results, { service="time", success=(response~=nil), response_size=response and #response or 0,
                                error=response and "OK" or "No response" })
        log("UDP Time: " .. ((response and "PASS") or "FAIL"))
    end

    -- Custom
    for _, command in ipairs({"ping","time","stats","echo test123","info","help"}) do
        success = testSocket:send(command, testTargets.udp.host, testTargets.udp.ports.custom)
        if success then
            local response = select(1, testSocket:receive(2))
            table.insert(results, { service="custom", command=command, success=(response~=nil),
                                    response=response or "No response", error=response and "OK" or "Timeout" })
            log(string.format("UDP Custom '%s': %s", command, response and "PASS" or "FAIL"))
        end
    end

    -- Discovery
    success = testSocket:send("discover", testTargets.udp.host, testTargets.udp.ports.discovery)
    if success then
        local response = select(1, testSocket:receive(2))
        local ok = response ~= nil and response:match("discovery_response")
        table.insert(results, { service="discovery", success=ok, response=response or "No response",
                                error=ok and "OK" or (response and "Invalid response" or "No response") })
        log("UDP Discovery: " .. (ok and "PASS" or "FAIL"))
    end

    testSocket:close()
    testResults.udp = results
    return results
end

-- UI
local main, statusLabel, resultsList
local function createTestUI()
    local w, h = term.getSize()
    main = basalt.getMainFrame():setBackground(colors.blue):setSize(w, h)
    main:addLabel():setPosition(1, 1):setSize(w, 1)
        :setText("CC Network Test Client v" .. client.version)
        :setForeground(colors.white):setBackground(colors.blue)

    local statusPanel = main:addFrame():setPosition(2, 3):setSize(w-2, 6):setBackground(colors.white)
    statusPanel:addLabel():setPosition(1, 1):setText("Network Test Client"):setForeground(colors.black)
    statusLabel = statusPanel:addLabel():setPosition(1, 2):setText("Ready to test"):setForeground(colors.gray)

    local httpBtn = statusPanel:addButton():setPosition(2, 4):setSize(12, 1)
                               :setText("Test HTTP"):setBackground(colors.green):setForeground(colors.white)
    local wsBtn   = statusPanel:addButton():setPosition(15, 4):setSize(12, 1)
                               :setText("Test WebSocket"):setBackground(colors.orange):setForeground(colors.white)
    local udpBtn  = statusPanel:addButton():setPosition(28, 4):setSize(12, 1)
                               :setText("Test UDP"):setBackground(colors.cyan):setForeground(colors.white)
    local allBtn  = statusPanel:addButton():setPosition(41, 4):setSize(8, 1)
                               :setText("Test All"):setBackground(colors.purple):setForeground(colors.white)

    local resultsPanel = main:addFrame():setPosition(2, 10):setSize(w-2, h-10):setBackground(colors.black)
    resultsPanel:addLabel():setPosition(1, 1):setText("Test Results"):setForeground(colors.white)
    resultsList = resultsPanel:addList():setPosition(1, 2):setSize(w-2, h-12)
                              :setBackground(colors.black):setForeground(colors.white)

    httpBtn:onClick(function()
        statusLabel:setText("Running HTTP tests...")
        local results = testHTTP()
        resultsList:clear()
        resultsList:addItem("=== HTTP Test Results ===", colors.yellow)
        for _, r in ipairs(results) do
            resultsList:addItem(string.format("%s: %s (%d)", r.endpoint, r.success and "PASS" or "FAIL", r.status_code),
                    r.success and colors.green or colors.red)
        end
        statusLabel:setText("HTTP tests completed")
    end)

    wsBtn:onClick(function()
        statusLabel:setText("Running WebSocket tests...")
        local results = testWebSocket()
        resultsList:clear()
        resultsList:addItem("=== WebSocket Test Results ===", colors.yellow)
        if results.error then
            resultsList:addItem("ERROR: " .. results.error, colors.red)
        else
            for _, r in ipairs(results) do
                resultsList:addItem(string.format("%s: %s", r.command, r.success and "PASS" or "FAIL"),
                        r.success and colors.green or colors.red)
            end
        end
        statusLabel:setText("WebSocket tests completed")
    end)

    udpBtn:onClick(function()
        statusLabel:setText("Running UDP tests...")
        local results = testUDP()
        resultsList:clear()
        resultsList:addItem("=== UDP Test Results ===", colors.yellow)
        if results.error then
            resultsList:addItem("ERROR: " .. results.error, colors.red)
        else
            for _, r in ipairs(results) do
                local label = r.command or r.service
                resultsList:addItem(string.format("%s: %s", label, r.success and "PASS" or "FAIL"),
                        r.success and colors.green or colors.red)
            end
        end
        statusLabel:setText("UDP tests completed")
    end)

    allBtn:onClick(function()
        statusLabel:setText("Running all tests...")
        resultsList:clear()

        local httpR = testHTTP()
        local wsR   = testWebSocket()
        local udpR  = testUDP()

        resultsList:addItem("=== Complete Test Results ===", colors.yellow)
        resultsList:addItem("HTTP:", colors.cyan)
        for _, r in ipairs(httpR) do
            resultsList:addItem("  " .. r.endpoint .. ": " .. (r.success and "PASS" or "FAIL"),
                    r.success and colors.green or colors.red)
        end
        resultsList:addItem("WebSocket:", colors.cyan)
        if wsR.error then
            resultsList:addItem("  ERROR: " .. wsR.error, colors.red)
        else
            for _, r in ipairs(wsR) do
                resultsList:addItem("  " .. r.command .. ": " .. (r.success and "PASS" or "FAIL"),
                        r.success and colors.green or colors.red)
            end
        end
        resultsList:addItem("UDP:", colors.cyan)
        if udpR.error then
            resultsList:addItem("  ERROR: " .. udpR.error, colors.red)
        else
            for _, r in ipairs(udpR) do
                local label = r.command or r.service
                resultsList:addItem("  " .. label .. ": " .. (r.success and "PASS" or "FAIL"),
                        r.success and colors.green or colors.red)
            end
        end

        statusLabel:setText("All tests completed")
    end)

    local exitBtn = main:addButton():setPosition(w-8, h):setSize(8, 1)
                        :setText("Exit"):setBackground(colors.red):setForeground(colors.white)
    exitBtn:onClick(function() client.running = false end)
end

-- Main execution
local function main_loop()
    createTestUI()

    local networkStatus = rednet.isOpen() and "Network: OK" or "Network: Offline"
    local udpStatus = (udp and "UDP: Available") or "UDP: Not Available"
    statusLabel:setText(networkStatus .. " | " .. udpStatus)

    while client.running do
        local ev = { os.pullEventRaw() }
        basalt.update(table.unpack(ev))
        if ev[1] == "terminate" then client.running = false end
    end

    term.clear(); term.setCursorPos(1, 1)
    print("Network Test Client exited.")
end

-- Export
client.testHTTP = testHTTP
client.testWebSocket = testWebSocket
client.testUDP = testUDP
client.testResults = testResults

if not _G.network_test_client then
    _G.network_test_client = client
    main_loop()
end

return client
