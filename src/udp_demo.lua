-- UDP Protocol Demonstration
-- Shows various UDP capabilities in the CC Networking system

local function printHeader(text)
    print("\n" .. string.rep("=", 40))
    print(text)
    print(string.rep("=", 40))
end

local function printStatus(success, message)
    if success then
        print("[OK] " .. message)
    else
        print("[FAIL] " .. message)
    end
end

-- Check system requirements
local function checkRequirements()
    printHeader("System Requirements Check")

    -- Check for modem
    local modem = peripheral.find("modem")
    printStatus(modem ~= nil, "Modem available")

    -- Check for netd
    local netdRunning = fs.exists("/var/run/netd.pid")
    printStatus(netdRunning, "Network daemon (netd) running")

    -- Check for UDP protocol
    local udpExists = fs.exists("/protocols/udp.lua")
    printStatus(udpExists, "UDP protocol installed")

    -- Check for network library
    local netLibExists = fs.exists("/lib/network.lua")
    printStatus(netLibExists, "Network library available")

    if not modem then
        print("\nERROR: No modem found. UDP requires a modem.")
        return false
    end

    if not udpExists then
        print("\nERROR: UDP protocol not installed.")
        print("Please run the installation script first.")
        return false
    end

    return true
end

-- Load required libraries
local function loadLibraries()
    printHeader("Loading Libraries")

    local libs = {}

    -- Load UDP protocol directly
    local success, udp = pcall(dofile, "/protocols/udp.lua")
    if success then
        libs.udp = udp
        print("Loaded UDP protocol v" .. (udp.version or "unknown"))
    else
        print("Failed to load UDP protocol: " .. tostring(udp))
        return nil
    end

    -- Load network library if available
    if fs.exists("/lib/network.lua") then
        success, network = pcall(dofile, "/lib/network.lua")
        if success then
            libs.network = network
            print("Loaded network library")
        end
    end

    return libs
end

-- Demo 1: Basic UDP Socket Creation
local function demoBasicSocket(libs)
    printHeader("Demo 1: Basic UDP Socket")

    print("Creating UDP socket on random port...")
    local socket = libs.udp.socket()
    print("Socket created on port: " .. socket.port)

    print("\nSocket information:")
    print("  Port: " .. socket.port)
    print("  Bound: " .. tostring(socket.bound))

    print("\nClosing socket...")
    socket:close()
    print("Socket closed")

    return true
end

-- Demo 2: UDP Echo Server
local function demoEchoServer(libs)
    printHeader("Demo 2: UDP Echo Server")

    local port = 12345
    print("Starting echo server on port " .. port)

    local server = libs.udp.socket(port)
    server:bind(port)
    print("Server bound to port " .. port)

    -- Set up receive callback
    local receivedCount = 0
    server:setReceiveCallback(function(data, sender)
        receivedCount = receivedCount + 1
        print(string.format("Received from %s:%d: %s",
                sender.ip, sender.port, tostring(data)))

        -- Echo back
        server:send("Echo: " .. data, sender.ip, sender.port)
        print("Echoed back to sender")
    end)

    print("\nEcho server running for 10 seconds...")
    print("Open another computer and run the client demo")

    -- Run for 10 seconds
    local timer = os.startTimer(10)
    while true do
        local event, p1 = os.pullEvent("timer")
        if p1 == timer then
            break
        end
    end

    print("\nServer statistics:")
    print("  Packets received: " .. receivedCount)
    local stats = server:getStatistics()
    print("  Packets sent: " .. stats.packets_sent)
    print("  Bytes sent: " .. stats.bytes_sent)
    print("  Bytes received: " .. stats.bytes_received)

    server:close()
    print("Echo server stopped")

    return true
end

-- Demo 3: UDP Client
local function demoClient(libs)
    printHeader("Demo 3: UDP Client")

    print("Enter server IP (or press Enter for localhost):")
    local serverIP = read()
    if serverIP == "" then
        serverIP = "127.0.0.1"
    end

    local serverPort = 12345
    print("Connecting to " .. serverIP .. ":" .. serverPort)

    local client = libs.udp.socket()
    print("Client socket created on port " .. client.port)

    -- Send test packets
    local messages = {
        "Hello, UDP!",
        "This is a test message",
        "ComputerCraft networking",
        "UDP protocol works!"
    }

    print("\nSending test messages...")
    for i, msg in ipairs(messages) do
        local success, err = client:send(msg, serverIP, serverPort)
        if success then
            print("  [" .. i .. "] Sent: " .. msg)
        else
            print("  [" .. i .. "] Failed: " .. (err or "unknown error"))
        end
        sleep(0.5)
    end

    print("\nWaiting for responses...")
    for i = 1, 4 do
        local data, sender = client:receive(2)  -- 2 second timeout
        if data then
            print("  Received: " .. data)
        else
            print("  Timeout waiting for response " .. i)
        end
    end

    client:close()
    print("\nClient demo completed")

    return true
end

-- Demo 4: UDP Broadcast
local function demoBroadcast(libs)
    printHeader("Demo 4: UDP Broadcast")

    print("Setting up broadcast demonstration...")

    -- Create sender socket
    local broadcaster = libs.udp.socket()
    print("Broadcaster on port: " .. broadcaster.port)

    -- For broadcast in CC, we use special broadcast addresses
    local broadcastIP = "255.255.255.255"
    local broadcastPort = 9999

    print("\nBroadcasting discovery message...")
    local message = {
        type = "discovery",
        hostname = os.getComputerLabel() or "Computer",
        id = os.getComputerID(),
        timestamp = os.epoch("utc")
    }

    local success = broadcaster:send(
            textutils.serialize(message),
            broadcastIP,
            broadcastPort
    )

    if success then
        print("Broadcast sent successfully")
    else
        print("Broadcast failed")
    end

    broadcaster:close()
    return true
end

-- Demo 5: UDP Statistics
local function demoStatistics(libs)
    printHeader("Demo 5: UDP Statistics")

    local stats = libs.udp.getStatistics()

    print("Global UDP Statistics:")
    print("  Packets sent: " .. stats.packets_sent)
    print("  Packets received: " .. stats.packets_received)
    print("  Bytes sent: " .. stats.bytes_sent)
    print("  Bytes received: " .. stats.bytes_received)
    print("  Packets dropped: " .. stats.packets_dropped)
    print("  Active sockets: " .. stats.active_sockets)

    if stats.sockets then
        print("\nPer-socket statistics:")
        for port, sockStats in pairs(stats.sockets) do
            print("  Port " .. port .. ":")
            print("    Sent: " .. sockStats.packets_sent .. " packets")
            print("    Received: " .. sockStats.packets_received .. " packets")
        end
    end

    return true
end

-- Demo 6: Integration with Network Library
local function demoNetworkIntegration(libs)
    if not libs.network then
        print("\nNetwork library not available, skipping integration demo")
        return false
    end

    printHeader("Demo 6: Network Library Integration")

    print("Using network library UDP functions...")

    -- Create UDP socket via network library
    local socket = libs.network.udpSocket(5555)
    print("Created socket via network library on port 5555")

    -- Send datagram via network library
    local success = libs.network.udpSend("10.0.0.1", 5000, "Test from network lib")
    printStatus(success, "Sent UDP datagram via network library")

    -- Set up listener
    local listener = libs.network.udpListen(6666, function(data, sender)
        print("Received via network library: " .. tostring(data))
    end)

    if listener then
        print("UDP listener set up on port 6666")
        listener:close()
    end

    return true
end

-- Interactive menu
local function showMenu()
    printHeader("UDP Demo Menu")
    print("1. Basic Socket Creation")
    print("2. Echo Server (run this first)")
    print("3. Client (run on another computer)")
    print("4. Broadcast Demo")
    print("5. Show Statistics")
    print("6. Network Library Integration")
    print("7. Run All Demos")
    print("8. Exit")
    print("\nSelect option (1-8): ")
end

-- Main program
local function main()
    term.clear()
    term.setCursorPos(1, 1)

    printHeader("CC Networking - UDP Protocol Demo")

    -- Check requirements
    if not checkRequirements() then
        print("\nPlease fix the issues above and try again.")
        return
    end

    -- Load libraries
    local libs = loadLibraries()
    if not libs then
        print("\nFailed to load required libraries.")
        return
    end

    -- Interactive menu loop
    while true do
        showMenu()
        local choice = read()

        if choice == "1" then
            demoBasicSocket(libs)
        elseif choice == "2" then
            demoEchoServer(libs)
        elseif choice == "3" then
            demoClient(libs)
        elseif choice == "4" then
            demoBroadcast(libs)
        elseif choice == "5" then
            demoStatistics(libs)
        elseif choice == "6" then
            demoNetworkIntegration(libs)
        elseif choice == "7" then
            -- Run all demos except server/client
            demoBasicSocket(libs)
            sleep(1)
            demoBroadcast(libs)
            sleep(1)
            demoStatistics(libs)
            sleep(1)
            demoNetworkIntegration(libs)
            print("\nAll automated demos completed!")
            print("Run options 2 and 3 manually for server/client demo")
        elseif choice == "8" then
            print("\nExiting UDP demo...")
            break
        else
            print("Invalid option, please try again")
        end

        if choice ~= "8" then
            print("\nPress any key to continue...")
            os.pullEvent("key")
        end
    end

    print("Thank you for trying the UDP protocol demo!")
end

-- Run the demo
main()