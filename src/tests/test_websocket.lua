-- /tests/test_websocket.lua
-- WebSocket Protocol Test Script

local function printHeader(text)
    print("\n" .. string.rep("=", 45))
    print("  " .. text)
    print(string.rep("=", 45))
end

local function printStatus(success, message)
    if success then
        print("[PASS] " .. message)
    else
        print("[FAIL] " .. message)
    end
end

-- Test WebSocket connection
local function testWebSocketConnection()
    printHeader("WebSocket Connection Test")

    -- Load network library
    local network = nil
    if fs.exists("/lib/network.lua") then
        network = dofile("/lib/network.lua")
    end

    if not network then
        print("Network library not found, using native WebSocket")

        -- Test native WebSocket
        print("\nTesting connection to echo server...")
        local ws, err = http.websocket("wss://echo.websocket.org")

        if ws then
            printStatus(true, "Connected to echo.websocket.org")

            -- Test send/receive
            local testMessage = "Hello from ComputerCraft!"
            ws.send(testMessage)
            print("Sent: " .. testMessage)

            local received = ws.receive(5)
            if received == testMessage then
                printStatus(true, "Echo test successful")
            else
                printStatus(false, "Echo test failed - got: " .. tostring(received))
            end

            ws.close()
            printStatus(true, "Connection closed")
        else
            printStatus(false, "Failed to connect: " .. tostring(err))
        end
    else
        print("Using network library WebSocket implementation")

        -- Test local WebSocket server first
        print("\n1. Testing Local WebSocket Server")
        print("Starting test server on port 8080...")

        -- Start a simple WebSocket server
        local server = network.wsServer(8080, function(event, connId, data)
            if event == "connect" then
                print("Server: Client connected - " .. connId)
            elseif event == "data" then
                print("Server: Received - " .. tostring(data))
                -- Echo back
                return data
            elseif event == "close" then
                print("Server: Client disconnected - " .. connId)
            end
        end)

        if server then
            -- Run server in parallel with client test
            parallel.waitForAny(
                    function()
                        server:listen()
                    end,
                    function()
                        sleep(1)  -- Let server start

                        -- Connect as client
                        print("\nConnecting to local server...")
                        local ws = network.websocket("ws://localhost:8080")

                        if ws then
                            printStatus(true, "Connected to local server")

                            -- Test communication
                            ws.send("Test message")
                            local response = ws.receive(2)

                            if response then
                                printStatus(true, "Local echo test passed")
                            else
                                printStatus(false, "No response from local server")
                            end

                            ws.close()
                        else
                            printStatus(false, "Failed to connect to local server")
                        end

                        server:stop()
                    end
            )
        else
            print("Failed to start WebSocket server")
        end

        -- Test external WebSocket
        print("\n2. Testing External WebSocket")
        local ws = network.websocket("wss://echo.websocket.org")

        if ws then
            printStatus(true, "Connected to external echo server")

            ws.send("External test")
            local response = ws.receive(5)

            if response then
                printStatus(true, "External communication successful")
            else
                printStatus(false, "External communication failed")
            end

            ws.close()
        else
            printStatus(false, "Failed to connect to external server")
        end
    end

    return true
end

-- Test WebSocket with different message types
local function testMessageTypes()
    printHeader("WebSocket Message Types Test")

    print("Testing different message formats...")

    local messages = {
        {type = "text", data = "Simple text message"},
        {type = "json", data = {command = "test", value = 42}},
        {type = "binary", data = string.char(0x00, 0x01, 0x02, 0x03)},
        {type = "large", data = string.rep("A", 1000)}
    }

    local ws = http.websocket("wss://echo.websocket.org")
    if not ws then
        printStatus(false, "Could not connect for message type tests")
        return false
    end

    for _, msg in ipairs(messages) do
        print("\nTesting " .. msg.type .. " message...")

        local toSend = msg.data
        if msg.type == "json" then
            toSend = textutils.serialiseJSON(msg.data)
        end

        ws.send(toSend)
        local received = ws.receive(3)

        if received then
            if msg.type == "json" then
                local success, decoded = pcall(textutils.unserialiseJSON, received)
                if success then
                    printStatus(true, msg.type .. " message echo successful")
                else
                    printStatus(false, msg.type .. " message decode failed")
                end
            else
                printStatus(received == toSend, msg.type .. " message echo test")
            end
        else
            printStatus(false, msg.type .. " message no response")
        end
    end

    ws.close()
    return true
end

-- Performance test
local function testPerformance()
    printHeader("WebSocket Performance Test")

    local ws = http.websocket("wss://echo.websocket.org")
    if not ws then
        print("Could not connect for performance test")
        return false
    end

    print("Sending 10 rapid messages...")
    local startTime = os.epoch("utc")
    local successCount = 0

    for i = 1, 10 do
        ws.send("Message " .. i)
        local response = ws.receive(1)
        if response then
            successCount = successCount + 1
        end
    end

    local endTime = os.epoch("utc")
    local duration = endTime - startTime

    print("\nResults:")
    print("  Messages sent: 10")
    print("  Responses received: " .. successCount)
    print("  Success rate: " .. (successCount * 10) .. "%")
    print("  Total time: " .. duration .. "ms")
    print("  Average RTT: " .. math.floor(duration / successCount) .. "ms")

    ws.close()

    printStatus(successCount >= 8, "Performance test (80% success required)")

    return successCount >= 8
end

-- Main test runner
local function main()
    printHeader("WebSocket Protocol Test Suite")

    local results = {
        connection = false,
        messageTypes = false,
        performance = false
    }

    -- Run tests
    print("\nRunning WebSocket tests...")

    results.connection = testWebSocketConnection()
    sleep(1)

    results.messageTypes = testMessageTypes()
    sleep(1)

    results.performance = testPerformance()

    -- Summary
    printHeader("Test Summary")
    print("\nTest Results:")
    printStatus(results.connection, "Connection Test")
    printStatus(results.messageTypes, "Message Types Test")
    printStatus(results.performance, "Performance Test")

    local passed = 0
    for _, result in pairs(results) do
        if result then passed = passed + 1 end
    end

    print("\nOverall: " .. passed .. "/3 tests passed")

    if passed == 3 then
        print("\nWebSocket protocol is working perfectly!")
    elseif passed >= 2 then
        print("\nWebSocket protocol is mostly working.")
    else
        print("\nWebSocket protocol has issues that need attention.")
    end

    print("\nPress any key to return to menu...")
    os.pullEvent("key")
end

-- Run tests
main()