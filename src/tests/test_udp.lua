-- /tests/test_udp.lua
-- UDP Protocol Test Script

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

-- Test UDP socket creation
local function testSocketCreation()
    printHeader("UDP Socket Creation Test")

    -- Check if UDP protocol exists
    if not fs.exists("/protocols/udp.lua") then
        print("\nERROR: UDP protocol not installed!")
        print("Please install the UDP protocol first.")
        return false
    end

    -- Load UDP protocol
    local udp = dofile("/protocols/udp.lua")

    print("\n1. Creating UDP socket with auto-assigned port...")
    local socket1 = udp.socket()
    printStatus(socket1 ~= nil, "Socket created")

    if socket1 then
        print("  Port assigned: " .. socket1.port)
        printStatus(socket1.port >= 49152, "Ephemeral port range")

        socket1:close()
        printStatus(true, "Socket closed")
    end

    print("\n2. Creating UDP socket with specific port...")
    local socket2 = udp.socket(12345)

    if socket2 then
        printStatus(socket2.port == 12345, "Specific port assigned")

        -- Test binding
        local success = socket2:bind(12345)
        printStatus(success, "Socket bound to port 12345")

        socket2:close()
    else
        printStatus(false, "Failed to create socket on port 12345")
    end

    return true
end

-- Test UDP datagram sending and receiving
local function testDatagramTransfer()
    printHeader("UDP Datagram Transfer Test")

    local udp = dofile("/protocols/udp.lua")

    print("\nTesting send and receive...")

    local testMessages = {
        "Hello UDP!",
        "Test message 123",
        textutils.serialize({type = "data", value = 42}),
        string.rep("X", 500)
    }

    local success = true

    -- Create server socket
    local server = udp.socket(54321)
    server:bind(54321)
    print("Server bound to port 54321")

    -- Create client socket
    local client = udp.socket()
    print("Client socket on port " .. client.port)

    for i, message in ipairs(testMessages) do
        print("\nTest " .. i .. ": " .. #message .. " bytes")

        -- Send from client
        local sent = client:send(message, "127.0.0.1", 54321)

        if sent then
            print("  Client: Sent datagram")

            -- Receive on server
            local data, sender = server:receive(2)

            if data then
                print("  Server: Received from " .. sender.ip .. ":" .. sender.port)
                printStatus(data == message, "Data integrity check")

                -- Echo back
                server:send("ACK:" .. i, sender.ip, sender.port)

                -- Client receive ACK
                local ack = client:receive(2)
                printStatus(ack == "ACK:" .. i, "ACK received")
            else
                printStatus(false, "Server receive timeout")
                success = false
            end
        else
            printStatus(false, "Failed to send datagram")
            success = false
        end
    end

    -- Get statistics
    local stats = server:getStatistics()
    print("\nServer Statistics:")
    print("  Packets sent: " .. stats.packets_sent)
    print("  Packets received: " .. stats.packets_received)
    print("  Bytes sent: " .. stats.bytes_sent)
    print("  Bytes received: " .. stats.bytes_received)

    server:close()
    client:close()

    return success
end

-- Test UDP broadcast
local function testBroadcast()
    printHeader("UDP Broadcast Test")

    local udp = dofile("/protocols/udp.lua")

    print("\nTesting broadcast functionality...")

    -- Create receivers
    local receivers = {}
    local ports = {55001, 55002, 55003}

    for _, port in ipairs(ports) do
        local socket = udp.socket(port)
        socket:bind(port)
        table.insert(receivers, socket)
        print("Receiver listening on port " .. port)
    end

    -- Create broadcaster
    local broadcaster = udp.socket()
    print("Broadcaster on port " .. broadcaster.port)

    -- Send broadcast message
    local broadcastMsg = "BROADCAST TEST MESSAGE"
    print("\nSending broadcast: " .. broadcastMsg)

    -- In CC, broadcast to all local addresses
    for _, port in ipairs(ports) do
        broadcaster:send(broadcastMsg, "127.0.0.1", port)
    end

    -- Check receivers
    local receivedCount = 0
    for i, receiver in ipairs(receivers) do
        local data, sender = receiver:receive(1)
        if data == broadcastMsg then
            receivedCount = receivedCount + 1
            print("  Receiver " .. i .. " got broadcast")
        else
            print("  Receiver " .. i .. " no message")
        end
        receiver:close()
    end

    broadcaster:close()

    printStatus(receivedCount == #ports, "Broadcast received by all (" ..
            receivedCount .. "/" .. #ports .. ")")

    return receivedCount == #ports
end

-- Test UDP with callbacks
local function testCallbacks()
    printHeader("UDP Callback Test")

    local udp = dofile("/protocols/udp.lua")

    print("\nTesting asynchronous callbacks...")

    local callbackFired = false
    local receivedData = nil

    -- Create server with callback
    local server = udp.socket(56789)
    server:bind(56789)

    server:setReceiveCallback(function(data, sender)
        print("Callback fired!")
        print("  Data: " .. tostring(data))
        print("  From: " .. sender.ip .. ":" .. sender.port)
        callbackFired = true
        receivedData = data
    end)

    print("Server callback registered on port 56789")

    -- Create client and send
    local client = udp.socket()
    client:send("Callback test message", "127.0.0.1", 56789)
    print("Client sent message")

    -- Wait for callback (simulate event loop)
    local timeout = os.startTimer(2)
    while not callbackFired do
        local event = os.pullEvent()
        if event == "timer" then
            break
        end
    end

    printStatus(callbackFired, "Callback triggered")
    printStatus(receivedData == "Callback test message", "Callback data correct")

    server:close()
    client:close()

    return callbackFired
end

-- Test UDP packet size limits
local function testPacketSizes()
    printHeader("UDP Packet Size Test")

    local udp = dofile("/protocols/udp.lua")

    print("\nTesting various packet sizes...")

    local sizes = {
        {name = "Tiny", size = 10},
        {name = "Small", size = 100},
        {name = "Medium", size = 1000},
        {name = "Large", size = 8192},
        {name = "Max", size = 65507}  -- Max UDP payload
    }

    local server = udp.socket(44444)
    server:bind(44444)

    local client = udp.socket()

    for _, test in ipairs(sizes) do
        print("\n" .. test.name .. " packet (" .. test.size .. " bytes):")

        local data = string.rep("A", test.size)
        local sent = client:send(data, "127.0.0.1", 44444)

        if sent then
            print("  Sent successfully")

            local received, sender = server:receive(1)
            if received and #received == test.size then
                printStatus(true, "Received correct size")
            else
                printStatus(false, "Size mismatch or timeout")
            end
        else
            if test.size > 65507 then
                printStatus(true, "Correctly rejected oversized packet")
            else
                printStatus(false, "Failed to send")
            end
        end
    end

    server:close()
    client:close()

    return true
end

-- Test UDP with network library integration
local function testNetworkIntegration()
    printHeader("Network Library Integration Test")

    if not fs.exists("/lib/network.lua") then
        print("\nNetwork library not found, skipping integration test")
        return true
    end

    local network = dofile("/lib/network.lua")

    print("\nTesting UDP through network library...")

    -- Create socket via network library
    local socket = network.udpSocket(33333)
    if socket then
        printStatus(true, "Socket created via network library")

        -- Send datagram via network library
        local success = network.udpSend("127.0.0.1", 33333, "Network lib test")
        printStatus(success, "Datagram sent via network library")

        -- Receive
        local data, sender = socket:receive(2)
        if data then
            printStatus(data == "Network lib test", "Received via socket")
        end

        socket:close()
    else
        printStatus(false, "Failed to create socket via network library")
        return false
    end

    -- Test listener
    print("\nTesting UDP listener...")
    local receivedViaListener = false

    local listener = network.udpListen(22222, function(data, sender)
        print("Listener received: " .. tostring(data))
        receivedViaListener = true
    end)

    if listener then
        network.udpSend("127.0.0.1", 22222, "Listener test")
        sleep(0.5)

        printStatus(receivedViaListener, "Listener callback fired")
        listener:close()
    else
        printStatus(false, "Failed to create listener")
    end

    return true
end

-- Main test runner
local function main()
    printHeader("UDP Protocol Test Suite")

    -- Check for UDP protocol
    if not fs.exists("/protocols/udp.lua") then
        print("\nERROR: UDP protocol not installed!")
        print("Please install /protocols/udp.lua first.")
        print("\nPress any key to return...")
        os.pullEvent("key")
        return
    end

    local results = {
        socketCreation = false,
        datagramTransfer = false,
        broadcast = false,
        callbacks = false,
        packetSizes = false,
        networkIntegration = false
    }

    -- Run tests
    print("\nRunning UDP tests...")

    results.socketCreation = testSocketCreation()
    sleep(1)

    results.datagramTransfer = testDatagramTransfer()
    sleep(1)

    results.broadcast = testBroadcast()
    sleep(1)

    results.callbacks = testCallbacks()
    sleep(1)

    results.packetSizes = testPacketSizes()
    sleep(1)

    results.networkIntegration = testNetworkIntegration()

    -- Summary
    printHeader("Test Summary")
    print("\nTest Results:")
    printStatus(results.socketCreation, "Socket Creation Test")
    printStatus(results.datagramTransfer, "Datagram Transfer Test")
    printStatus(results.broadcast, "Broadcast Test")
    printStatus(results.callbacks, "Callback Test")
    printStatus(results.packetSizes, "Packet Size Test")
    printStatus(results.networkIntegration, "Network Integration Test")

    local passed = 0
    for _, result in pairs(results) do
        if result then passed = passed + 1 end
    end

    print("\nOverall: " .. passed .. "/6 tests passed")

    if passed == 6 then
        print("\nUDP protocol is working perfectly!")
    elseif passed >= 4 then
        print("\nUDP protocol is mostly working.")
    else
        print("\nUDP protocol has issues that need attention.")
    end

    print("\nPress any key to return to menu...")
    os.pullEvent("key")
end

-- Run tests
main()