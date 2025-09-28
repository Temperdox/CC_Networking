-- test_network.lua
-- Main network protocol testing menu system
-- ComputerCraft compatible version with server launcher integration

local function printHeader(text)
    term.clear()
    term.setCursorPos(1, 1)
    print(string.rep("=", 50))
    print("  " .. text)
    print(string.rep("=", 50))
end

local function printColored(text, color)
    if term.isColor() then
        term.setTextColor(color or colors.white)
    end
    print(text)
    if term.isColor() then
        term.setTextColor(colors.white)
    end
end

-- Protocol definitions with correct file paths
local PROTOCOLS = {
    {id = "websocket", name = "WebSocket", file = "/tests/test_websocket.lua", protocol_file = "/protocols/websocket.lua"},
    {id = "http_client", name = "HTTP", file = "/tests/test_http.lua", protocol_file = "/protocols/http_client.lua"},
    {id = "https", name = "HTTPS", file = "/tests/test_https.lua", protocol_file = "/protocols/https.lua"},
    {id = "webrtc", name = "WebRTC", file = "/tests/test_webrtc.lua", protocol_file = "/protocols/webrtc.lua"},
    {id = "tcp", name = "TCP", file = "/tests/test_tcp.lua", protocol_file = "/protocols/tcp.lua"},
    {id = "udp", name = "UDP", file = "/tests/test_udp.lua", protocol_file = "/protocols/udp.lua"},
    {id = "mqtt", name = "MQTT", file = "/tests/test_mqtt.lua", protocol_file = "/protocols/mqtt.lua"},
    {id = "ftp", name = "FTP", file = "/tests/test_ftp.lua", protocol_file = "/protocols/ftp.lua"},
    {id = "ssh", name = "SSH", file = "/tests/test_ssh.lua", protocol_file = "/protocols/ssh.lua"}
}

-- Global state for test components
local serverLauncher = nil
local testClient = nil

-- Ensure required directories exist
local function ensureDirectories()
    local dirs = {"/tests", "/tests/servers", "/var/log", "/var/run"}
    for _, dir in ipairs(dirs) do
        if not fs.exists(dir) then
            fs.makeDir(dir)
        end
    end
end

-- Load test components safely
local function loadTestComponents()
    printHeader("Loading Test Components")

    -- Reset components
    serverLauncher = nil
    testClient = nil

    -- Try to load server launcher
    if fs.exists("/tests/servers/launcher.lua") then
        local success, result = pcall(dofile, "/tests/servers/launcher.lua")
        if success and type(result) == "table" then
            serverLauncher = result
            printColored("Server launcher: OK", colors.green)
        else
            printColored("Server launcher: Failed to load", colors.yellow)
            if result then
                print("Error: " .. tostring(result))
            end
        end
    else
        printColored("Server launcher: Not found", colors.gray)
    end

    -- Try to load test client
    if fs.exists("/tests/test_client.lua") then
        local success, result = pcall(dofile, "/tests/test_client.lua")
        if success and type(result) == "table" then
            testClient = result
            printColored("Test client: OK", colors.green)
        else
            printColored("Test client: Failed to load", colors.yellow)
            if result then
                print("Error: " .. tostring(result))
            end
        end
    else
        printColored("Test client: Not found", colors.gray)
    end

    print("\nPress any key to continue...")
    os.pullEvent("key")
end

-- Check system status
local function checkSystemStatus()
    printHeader("System Status Check")
    print()

    -- Core system checks
    printColored("System Components:", colors.cyan)

    local modem = peripheral.find("modem")
    printColored(string.format("  Modem: %s", modem and "OK" or "FAIL"),
            modem and colors.green or colors.red)

    local rednetOpen = rednet.isOpen()
    printColored(string.format("  Rednet: %s", rednetOpen and "Open" or "Closed"),
            rednetOpen and colors.green or colors.orange)

    -- Network components
    print()
    printColored("Network Infrastructure:", colors.cyan)

    local netd = fs.exists("/var/run/netd.pid")
    printColored(string.format("  Network Daemon: %s", netd and "Running" or "Stopped"),
            netd and colors.green or colors.red)

    local networkLib = fs.exists("/lib/network.lua")
    printColored(string.format("  Network Library: %s", networkLib and "OK" or "Missing"),
            networkLib and colors.green or colors.yellow)

    local protocolsDir = fs.exists("/protocols")
    printColored(string.format("  Protocols Directory: %s", protocolsDir and "OK" or "Missing"),
            protocolsDir and colors.green or colors.red)

    -- GUI framework
    local basalt = fs.exists("basalt.lua")
    printColored(string.format("  Basalt Framework: %s", basalt and "OK" or "Missing"),
            basalt and colors.green or colors.yellow)

    -- Test infrastructure
    print()
    printColored("Test Infrastructure:", colors.cyan)

    printColored(string.format("  Server Launcher: %s", serverLauncher and "Loaded" or "Not Available"),
            serverLauncher and colors.green or colors.yellow)

    printColored(string.format("  Test Client: %s", testClient and "Loaded" or "Not Available"),
            testClient and colors.green or colors.yellow)

    -- Protocol availability
    print()
    printColored("Protocol Status:", colors.cyan)

    for _, proto in ipairs(PROTOCOLS) do
        local protocolExists = fs.exists(proto.protocol_file)
        local testExists = fs.exists(proto.file)

        local status = "Not Available"
        local color = colors.red

        if protocolExists and testExists then
            status = "Ready"
            color = colors.green
        elseif protocolExists then
            status = "No Test File"
            color = colors.yellow
        elseif testExists then
            status = "Protocol Missing"
            color = colors.orange
        end

        printColored(string.format("  %-12s: %s", proto.name, status), color)
    end

    print("\nPress any key to continue...")
    os.pullEvent("key")
end

-- Create a basic test file for a protocol
local function createBasicTestFile(protocol)
    local testTemplate = string.format([[
-- %s
-- Test file for %s protocol
-- Auto-generated by test_network.lua

local function printHeader(text)
    print("\n" .. string.rep("=", 40))
    print(text)
    print(string.rep("=", 40))
end

local function printColored(text, color)
    if term.isColor() then
        term.setTextColor(color or colors.white)
    end
    print(text)
    if term.isColor() then
        term.setTextColor(colors.white)
    end
end

local function test_%s()
    printHeader("%s Protocol Test")

    -- Check if protocol file exists
    local protocolFile = "%s"
    if not fs.exists(protocolFile) then
        printColored("ERROR: Protocol not found!", colors.red)
        print("Expected location: " .. protocolFile)
        print("Please install the protocol first.")
        return false
    end

    -- Try to load the protocol
    local success, protocolModule = pcall(dofile, protocolFile)
    if not success then
        printColored("ERROR: Failed to load protocol!", colors.red)
        print("Load error: " .. tostring(protocolModule))
        return false
    end

    printColored("Protocol loaded successfully!", colors.green)

    -- Basic validation
    if type(protocolModule) == "table" then
        print("\nProtocol module contents:")
        local count = 0
        for key, value in pairs(protocolModule) do
            local valueType = type(value)
            print(string.format("  %%s: %%s", key, valueType))
            count = count + 1
        end

        if count > 0 then
            printColored(string.format("Found %%d properties/functions", count), colors.green)
        else
            printColored("Warning: Empty protocol module", colors.yellow)
        end
    else
        printColored("Protocol module type: " .. type(protocolModule), colors.cyan)
    end

    -- TODO: Add specific protocol tests here
    printColored("\nBasic protocol validation completed", colors.green)
    print("TODO: Implement specific " .. "%s" .. " protocol tests")

    return true
end

-- Main test execution
local function main()
    local success = test_%s()

    print(string.rep("-", 40))
    if success then
        printColored("TEST PASSED", colors.green)
    else
        printColored("TEST FAILED", colors.red)
    end

    print("\nPress any key to return to menu...")
    os.pullEvent("key")
end

-- Run the test
main()
]], protocol.file, protocol.name, protocol.id, protocol.name,
            protocol.protocol_file, protocol.name, protocol.id)

    -- Create directory if it doesn't exist
    local dir = fs.getDir(protocol.file)
    if dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end

    -- Write the test file
    local file = fs.open(protocol.file, "w")
    if file then
        file.write(testTemplate)
        file.close()
        return true
    end

    return false
end

-- Run a single protocol test
local function runProtocolTest(protocol)
    printHeader("Testing " .. protocol.name .. " Protocol")

    -- Check if test file exists
    if not fs.exists(protocol.file) then
        print("\nTest file not found: " .. protocol.file)
        print("Would you like to create a basic test file? (y/n)")

        local answer = read()
        if answer:lower() == "y" then
            print("Creating test file...")
            if createBasicTestFile(protocol) then
                printColored("Test file created successfully!", colors.green)
                print("\nRunning test...")
                sleep(1)
            else
                printColored("Failed to create test file!", colors.red)
                print("\nPress any key to return...")
                os.pullEvent("key")
                return
            end
        else
            return
        end
    end

    -- Warn if protocol doesn't exist
    if not fs.exists(protocol.protocol_file) then
        printColored("Warning: Protocol file not found!", colors.yellow)
        print("Location: " .. protocol.protocol_file)
        print("Test may fail without the protocol.")
        print("\nContinue anyway? (y/n)")

        local answer = read()
        if answer:lower() ~= "y" then
            return
        end
    end

    -- Execute the test
    print("\nExecuting test...")
    local success, error = pcall(function()
        shell.run(protocol.file)
    end)

    if not success then
        print("\nTest execution failed!")
        printColored("Error: " .. tostring(error), colors.red)
        print("\nPress any key to return...")
        os.pullEvent("key")
    end
end

-- Server management interface
local function manageServers()
    if not serverLauncher then
        printHeader("Server Management")
        printColored("Server launcher not available!", colors.red)
        print("\nOptions:")
        print("1. Try to load server launcher")
        print("2. Return to main menu")
        print("\nChoice: ")

        local choice = read()
        if choice == "1" then
            loadTestComponents()
        end
        return
    end

    printHeader("Test Server Management")

    -- Get server configurations
    local servers = serverLauncher.serverConfigs or {}
    if next(servers) == nil then
        printColored("No servers configured!", colors.yellow)
        print("\nPress any key to return...")
        os.pullEvent("key")
        return
    end

    -- Display server status
    print("\nServer Status:")
    for serverType, config in pairs(servers) do
        local status = config.status or "unknown"
        local color = status == "running" and colors.green or colors.red
        printColored(string.format("  %-15s: %s (Port %d)",
                config.name or serverType, status, config.port or 0), color)
    end

    -- Management options
    print("\nManagement Options:")
    print("1. Start All Servers")
    print("2. Stop All Servers")
    print("3. Server Details")
    print("4. Launch Server GUI")
    print("5. Return to Main Menu")
    print("\nChoice: ")

    local choice = read()

    if choice == "1" then
        print("\nStarting all servers...")
        for serverType, _ in pairs(servers) do
            if serverLauncher.startServer then
                local success, message = serverLauncher.startServer(serverType)
                local color = success and colors.green or colors.red
                printColored(string.format("%s: %s", servers[serverType].name, message or "Unknown result"), color)
            end
        end

    elseif choice == "2" then
        print("\nStopping all servers...")
        for serverType, _ in pairs(servers) do
            if serverLauncher.stopServer then
                local success, message = serverLauncher.stopServer(serverType)
                local color = success and colors.green or colors.red
                printColored(string.format("%s: %s", servers[serverType].name, message or "Unknown result"), color)
            end
        end

    elseif choice == "3" then
        printHeader("Server Details")
        for serverType, config in pairs(servers) do
            print("\n" .. string.rep("-", 30))
            printColored(config.name or serverType, colors.cyan)

            if serverLauncher.getServerStats then
                local stats = serverLauncher.getServerStats(serverType)
                for key, value in pairs(stats) do
                    print(string.format("  %s: %s", key, tostring(value)))
                end
            else
                print("  No statistics available")
            end
        end

    elseif choice == "4" then
        printColored("Launching server management GUI...", colors.green)
        print("This will exit the current menu.")
        print("Continue? (y/n)")

        local answer = read()
        if answer:lower() == "y" then
            shell.run("/tests/servers/launcher.lua")
            return
        end
    end

    if choice ~= "5" then
        print("\nPress any key to continue...")
        os.pullEvent("key")
    end
end

-- Comprehensive network testing
local function runComprehensiveTests()
    if not testClient then
        printHeader("Comprehensive Network Tests")
        printColored("Test client not available!", colors.red)
        print("\nThe comprehensive test requires the test client.")
        print("Try loading test components first (option L).")
        print("\nPress any key to return...")
        os.pullEvent("key")
        return
    end

    printHeader("Comprehensive Network Testing")
    print("This will run tests for HTTP, WebSocket, and UDP protocols")
    print("using the integrated test client.")
    print("\nNote: Make sure test servers are running first.")
    print("\nContinue? (y/n)")

    local answer = read()
    if answer:lower() ~= "y" then
        return
    end

    print("\n" .. string.rep("=", 50))
    printColored("STARTING COMPREHENSIVE TESTS", colors.cyan)
    print(string.rep("=", 50))

    -- Test HTTP
    if testClient.testHTTP then
        print("\n" .. string.rep("-", 40))
        printColored("Testing HTTP Protocol", colors.yellow)
        local httpResults = testClient.testHTTP()

        if httpResults and type(httpResults) == "table" then
            for _, result in ipairs(httpResults) do
                if type(result) == "table" and result.endpoint then
                    local status = result.success and "PASS" or "FAIL"
                    local color = result.success and colors.green or colors.red
                    printColored(string.format("  %s: %s", result.endpoint, status), color)
                end
            end
        else
            printColored("  HTTP test returned no results", colors.yellow)
        end
    else
        printColored("  HTTP test function not available", colors.red)
    end

    -- Test WebSocket
    if testClient.testWebSocket then
        print("\n" .. string.rep("-", 40))
        printColored("Testing WebSocket Protocol", colors.yellow)
        local wsResults = testClient.testWebSocket()

        if wsResults and type(wsResults) == "table" then
            if wsResults.error then
                printColored("  ERROR: " .. wsResults.error, colors.red)
            else
                for _, result in ipairs(wsResults) do
                    if type(result) == "table" and result.command then
                        local status = result.success and "PASS" or "FAIL"
                        local color = result.success and colors.green or colors.red
                        printColored(string.format("  %s: %s", result.command, status), color)
                    end
                end
            end
        else
            printColored("  WebSocket test returned no results", colors.yellow)
        end
    else
        printColored("  WebSocket test function not available", colors.red)
    end

    -- Test UDP
    if testClient.testUDP then
        print("\n" .. string.rep("-", 40))
        printColored("Testing UDP Protocol", colors.yellow)
        local udpResults = testClient.testUDP()

        if udpResults and type(udpResults) == "table" then
            if udpResults.error then
                printColored("  ERROR: " .. udpResults.error, colors.red)
            else
                for _, result in ipairs(udpResults) do
                    if type(result) == "table" then
                        local desc = result.command or result.service or "unknown"
                        local status = result.success and "PASS" or "FAIL"
                        local color = result.success and colors.green or colors.red
                        printColored(string.format("  %s: %s", desc, status), color)
                    end
                end
            end
        else
            printColored("  UDP test returned no results", colors.yellow)
        end
    else
        printColored("  UDP test function not available", colors.red)
    end

    print("\n" .. string.rep("=", 50))
    printColored("COMPREHENSIVE TESTS COMPLETED", colors.cyan)
    print(string.rep("=", 50))
    print("\nPress any key to return...")
    os.pullEvent("key")
end

-- Main menu system
local function showMainMenu()
    while true do
        printHeader("Network Protocol Test Suite")
        print()
        printColored("Protocol Tests:", colors.cyan)

        -- List protocols with status
        for i, proto in ipairs(PROTOCOLS) do
            local protocolExists = fs.exists(proto.protocol_file)
            local testExists = fs.exists(proto.file)

            local status = "[Not Available]"
            if protocolExists and testExists then
                status = "[Ready]"
            elseif protocolExists then
                status = "[No Test]"
            elseif testExists then
                status = "[No Protocol]"
            end

            print(string.format("%d. %-12s %s", i, proto.name, status))
        end

        -- Additional options
        print()
        printColored("System Options:", colors.cyan)
        print("S. System Status Check")
        print("A. Run All Available Tests")
        print("C. Create Missing Test Files")
        print()
        printColored("Server Options:", colors.cyan)
        print("M. Manage Test Servers")
        print("T. Comprehensive Network Tests")
        print("G. Launch Test Client GUI")
        print()
        printColored("Utility Options:", colors.cyan)
        print("L. Load/Reload Test Components")
        print("Q. Quit")
        print()
        print("Enter your choice: ")

        local choice = read():lower()

        -- Handle menu choices
        if choice == "q" then
            printHeader("Exiting Test Suite")
            printColored("Thank you for using the Network Protocol Test Suite!", colors.green)
            break

        elseif choice == "s" then
            checkSystemStatus()

        elseif choice == "a" then
            printHeader("Running All Available Tests")
            local testsRun = 0

            for _, proto in ipairs(PROTOCOLS) do
                if fs.exists(proto.file) and fs.exists(proto.protocol_file) then
                    print("\n" .. string.rep("-", 40))
                    printColored("Testing " .. proto.name, colors.yellow)
                    runProtocolTest(proto)
                    testsRun = testsRun + 1
                end
            end

            print("\n" .. string.rep("=", 40))
            if testsRun > 0 then
                printColored(string.format("Completed %d tests", testsRun), colors.green)
            else
                printColored("No tests were available to run", colors.yellow)
                print("Use option 'C' to create test files first.")
            end
            print("\nPress any key to continue...")
            os.pullEvent("key")

        elseif choice == "c" then
            printHeader("Creating Missing Test Files")
            local created = 0

            for _, proto in ipairs(PROTOCOLS) do
                if not fs.exists(proto.file) then
                    print("Creating " .. proto.file .. "...")
                    if createBasicTestFile(proto) then
                        printColored("  Success", colors.green)
                        created = created + 1
                    else
                        printColored("  Failed", colors.red)
                    end
                else
                    print(proto.file .. " already exists")
                end
            end

            print(string.rep("-", 40))
            if created > 0 then
                printColored(string.format("Created %d test files", created), colors.green)
            else
                printColored("No test files needed creation", colors.yellow)
            end
            print("\nPress any key to continue...")
            os.pullEvent("key")

        elseif choice == "m" then
            manageServers()

        elseif choice == "t" then
            runComprehensiveTests()

        elseif choice == "g" then
            if testClient then
                printColored("Launching test client GUI...", colors.green)
                print("This will exit the current menu.")
                print("Continue? (y/n)")

                local answer = read()
                if answer:lower() == "y" then
                    shell.run("/tests/test_client.lua")
                end
            else
                printColored("Test client not available!", colors.red)
                print("Try option 'L' to load test components first.")
                print("\nPress any key to continue...")
                os.pullEvent("key")
            end

        elseif choice == "l" then
            loadTestComponents()

        else
            -- Try to parse as protocol number
            local num = tonumber(choice)
            if num and num >= 1 and num <= #PROTOCOLS then
                runProtocolTest(PROTOCOLS[num])
            else
                printColored("Invalid choice. Please try again.", colors.red)
                sleep(1)
            end
        end
    end
end

-- Main program entry point
local function main()
    -- Initial setup
    ensureDirectories()

    -- Check for critical requirements
    if not peripheral.find("modem") then
        printHeader("Critical Error")
        printColored("No modem found!", colors.red)
        print("Network testing requires a modem peripheral.")
        print("Please attach a modem and restart the test suite.")
        return
    end

    -- Welcome screen
    printHeader("ComputerCraft Network Protocol Test Suite")
    print()
    print("This test suite provides comprehensive testing")
    print("for network protocols in your CC system.")
    print()
    print("Features:")
    print("- Individual protocol testing")
    print("- Automatic test file generation")
    print("- Server management integration")
    print("- System status monitoring")
    print("- Comprehensive network testing")
    print()
    printColored("Press any key to start...", colors.cyan)
    os.pullEvent("key")

    -- Load test components
    loadTestComponents()

    -- Start main menu
    showMainMenu()
end

-- Execute the program
main()