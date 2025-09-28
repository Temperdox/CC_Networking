-- /tests/test_tcp.lua
-- TCP Protocol Test Script

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

-- Test TCP connection establishment
local function testTcpConnection()
    printHeader("TCP Connection Test")

    -- Check if TCP protocol exists
    if not fs.exists("/protocols/tcp.lua") then
        print("\nERROR: TCP protocol not installed!")
        print("Please install the TCP protocol first.")
        return false
    end

    -- Load TCP protocol
    local tcp = dofile("/protocols/tcp.lua")

    print("\n1. Testing TCP Three-Way Handshake...")

    -- Create server
    local server = tcp:new("0.0.0.0", 12345, {mode = "server"})
    server:bind(12345)
    server:listen()

    print("TCP server listening on port 12345")

    -- Run server and client in parallel
    local serverSuccess = false
    local clientSuccess = false

    parallel.waitForAll(
            function()
                -- Server accept connection
                local client, addr = server:accept(5)
                if client then
                    serverSuccess = true
                    print("Server: Connection accepted from " .. tostring(addr))

                    -- Echo server
                    local data = client:receive(5)
                    if data then
                        print("Server: Received: " .. data)
                        client:send("Echo: " .. data)
                    end

                    client:close()
                else
                    print("Server: Accept timeout")
                end
                server:close()
            end,
            function()
                sleep(0.5)  -- Let server start

                -- Client connect
                local client = tcp:new("localhost", 12345)
                local status, msg = client:connect()

                if status == tcp.STATUSES.CONNECTED then
                    clientSuccess = true
                    print("Client: Connected successfully")

                    -- Send test message
                    client:send("Hello TCP!")
                    local response = client:receive(5)

                    if response then
                        print("Client: Received response: " .. response)
                        printStatus(response == "Echo: Hello TCP!", "Echo test")
                    end

                    client:close()
                else
                    print("Client: Connection failed - " .. tostring(msg))
                end
            end
    )

    printStatus(serverSuccess and clientSuccess, "TCP connection established")

    return serverSuccess and clientSuccess
end

-- Test TCP data transfer
local function testDataTransfer()
    printHeader("TCP Data Transfer Test")

    local tcp = dofile("/protocols/tcp.lua")

    print("\nTesting various data sizes...")

    local testData = {
        {name = "Small", data = "Test"},
        {name = "Medium", data = string.rep("X", 100)},
        {name = "Large", data = string.rep("A", 1000)},
        {name = "Binary", data = string.char(0, 1, 2, 3, 4, 5, 6, 7, 8, 9)}
    }

    local results = {}

    for _, test in ipairs(testData) do
        print("\nTesting " .. test.name .. " data (" .. #test.data .. " bytes)...")

        local success = false

        parallel.waitForAll(
                function()
                    -- Server
                    local server = tcp:new("0.0.0.0", 12346)
                    server:bind(12346)
                    server:listen()

                    local client = server:accept(5)
                    if client then
                        local received = client:receive(5)
                        if received == test.data then
                            success = true
                            client:send("ACK")
                        else
                            client:send("NAK")
                        end
                        client:close()
                    end
                    server:close()
                end,
                function()
                    sleep(0.2)

                    -- Client
                    local client = tcp:new("localhost", 12346)
                    if client:connect() == tcp.STATUSES.CONNECTED then
                        client:send(test.data)
                        local ack = client:receive(5)

                        if ack == "ACK" then
                            print("  Data verified successfully")
                        else
                            print("  Data verification failed")
                        end

                        client:close()
                    end
                end
        )

        results[test.name] = success
        printStatus(success, test.name .. " data transfer")
    end

    return results["Small"] and results["Medium"] and results["Large"]
end

-- Test TCP flow control
local function testFlowControl()
    printHeader("TCP Flow Control Test")

    local tcp = dofile("/protocols/tcp.lua")

    print("\nTesting window size and flow control...")

    local success = false
    local messageCount = 10
    local receivedCount = 0

    parallel.waitForAll(
            function()
                -- Server with limited window
                local server = tcp:new("0.0.0.0", 12347, {
                    windowSize = 3,  -- Small window for testing
                    bufferSize = 5
                })
                server:bind(12347)
                server:listen()

                local client = server:accept(5)
                if client then
                    print("Server: Connection accepted")

                    -- Receive multiple messages
                    for i = 1, messageCount do
                        local data = client:receive(10)
                        if data then
                            receivedCount = receivedCount + 1
                            print("Server: Received message " .. i)
                            sleep(0.1)  -- Simulate slow processing
                        else
                            break
                        end
                    end

                    client:close()
                end
                server:close()
            end,
            function()
                sleep(0.5)

                -- Client sending rapidly
                local client = tcp:new("localhost", 12347)
                if client:connect() == tcp.STATUSES.CONNECTED then
                    print("Client: Sending " .. messageCount .. " messages rapidly...")

                    for i = 1, messageCount do
                        local sent = client:send("Message " .. i)
                        if sent then
                            print("Client: Sent message " .. i)
                        else
                            print("Client: Failed to send message " .. i)
                            break
                        end
                    end

                    sleep(2)  -- Wait for server to process
                    client:close()
                end
            end
    )

    success = receivedCount == messageCount
    printStatus(success, "Flow control (" .. receivedCount .. "/" .. messageCount .. " messages)")

    return success
end

-- Test TCP connection reliability
local function testReliability()
    printHeader("TCP Reliability Test")

    local tcp = dofile("/protocols/tcp.lua")

    print("\nTesting sequence numbers and acknowledgments...")

    local sequenceCorrect = true
    local lastSeq = -1

    parallel.waitForAll(
            function()
                -- Server tracking sequence
                local server = tcp:new("0.0.0.0", 12348, {
                    debug = true
                })
                server:bind(12348)
                server:listen()

                local client = server:accept(5)
                if client then
                    -- Check sequence numbers
                    for i = 1, 5 do
                        local data = client:receive(5)
                        if data then
                            local seq = tonumber(data:match("SEQ:(%d+)"))
                            if seq and seq > lastSeq then
                                lastSeq = seq
                                print("Server: Sequence " .. seq .. " OK")
                            else
                                sequenceCorrect = false
                                print("Server: Sequence error")
                            end

                            -- Send ACK
                            client:send("ACK:" .. seq)
                        end
                    end

                    client:close()
                end
                server:close()
            end,
            function()
                sleep(0.5)

                -- Client with sequence tracking
                local client = tcp:new("localhost", 12348)
                if client:connect() == tcp.STATUSES.CONNECTED then
                    for i = 1, 5 do
                        local seq = i * 100
                        client:send("SEQ:" .. seq .. " Data:" .. i)

                        local ack = client:receive(2)
                        if ack then
                            local ackSeq = tonumber(ack:match("ACK:(%d+)"))
                            if ackSeq == seq then
                                print("Client: ACK received for SEQ " .. seq)
                            else
                                print("Client: Wrong ACK received")
                                sequenceCorrect = false
                            end
                        end
                    end

                    client:close()
                end
            end
    )

    printStatus(sequenceCorrect, "Sequence number tracking")

    return sequenceCorrect
end

-- Test TCP statistics
local function testStatistics()
    printHeader("TCP Statistics Test")

    local tcp = dofile("/protocols/tcp.lua")

    print("\nGathering connection statistics...")

    local stats = nil

    parallel.waitForAll(
            function()
                local server = tcp:new("0.0.0.0", 12349)
                server:bind(12349)
                server:listen()

                local client = server:accept(5)
                if client then
                    -- Exchange some data
                    for i = 1, 3 do
                        local data = client:receive(5)
                        if data then
                            client:send("Reply " .. i)
                        end
                    end

                    -- Get server stats
                    if client.getStatistics then
                        local serverStats = client:getStatistics()
                        print("\nServer Statistics:")
                        print("  Packets sent: " .. (serverStats.packetsSent or 0))
                        print("  Packets received: " .. (serverStats.packetsReceived or 0))
                        print("  Bytes sent: " .. (serverStats.bytesSent or 0))
                        print("  Bytes received: " .. (serverStats.bytesReceived or 0))
                    end

                    client:close()
                end
                server:close()
            end,
            function()
                sleep(0.5)

                local client = tcp:new("localhost", 12349)
                if client:connect() == tcp.STATUSES.CONNECTED then
                    -- Send some data
                    for i = 1, 3 do
                        client:send("Test " .. i)
                        client:receive(2)
                    end

                    -- Get client stats
                    if client.getStatistics then
                        stats = client:getStatistics()
                        print("\nClient Statistics:")
                        print("  Packets sent: " .. (stats.packetsSent or 0))
                        print("  Packets received: " .. (stats.packetsReceived or 0))
                        print("  Bytes sent: " .. (stats.bytesSent or 0))
                        print("  Bytes received: " .. (stats.bytesReceived or 0))
                        print("  RTT: " .. (stats.rtt or 0) .. "ms")
                        print("  Retransmissions: " .. (stats.retransmissions or 0))
                    end

                    client:close()
                end
            end
    )

    printStatus(stats ~= nil, "Statistics collection")

    return stats ~= nil
end

-- Main test runner
local function main()
    printHeader("TCP Protocol Test Suite")

    -- Check for TCP protocol
    if not fs.exists("/protocols/tcp.lua") then
        print("\nERROR: TCP protocol not installed!")
        print("Please install /protocols/tcp.lua first.")
        print("\nPress any key to return...")
        os.pullEvent("key")
        return
    end

    local results = {
        connection = false,
        dataTransfer = false,
        flowControl = false,
        reliability = false,
        statistics = false
    }

    -- Run tests
    print("\nRunning TCP tests...")

    results.connection = testTcpConnection()
    sleep(1)

    results.dataTransfer = testDataTransfer()
    sleep(1)

    results.flowControl = testFlowControl()
    sleep(1)

    results.reliability = testReliability()
    sleep(1)

    results.statistics = testStatistics()

    -- Summary
    printHeader("Test Summary")
    print("\nTest Results:")
    printStatus(results.connection, "Connection Test")
    printStatus(results.dataTransfer, "Data Transfer Test")
    printStatus(results.flowControl, "Flow Control Test")
    printStatus(results.reliability, "Reliability Test")
    printStatus(results.statistics, "Statistics Test")

    local passed = 0
    for _, result in pairs(results) do
        if result then passed = passed + 1 end
    end

    print("\nOverall: " .. passed .. "/5 tests passed")

    if passed == 5 then
        print("\nTCP protocol is working perfectly!")
    elseif passed >= 3 then
        print("\nTCP protocol is mostly working.")
    else
        print("\nTCP protocol has issues that need attention.")
    end

    print("\nPress any key to return to menu...")
    os.pullEvent("key")
end

-- Run tests
main()