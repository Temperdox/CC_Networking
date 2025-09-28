-- test_network.lua
-- Main network protocol testing menu system with server launcher integration
-- Allows testing of all implemented network protocols and managing test servers

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

-- Protocol list with display names, test files, and actual protocol file locations
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

-- Server launcher and test client integration
local serverLauncher = nil
local testClient = nil

-- Load server launcher and test client if available
local function loadTestComponents()
    printHeader("Loading Test Components")

    -- Try to load server launcher
    if fs.exists("/tests/servers/launcher.lua") then
        local ok, launcher = pcall(dofile, "/tests/servers/launcher.lua")
        if ok and launcher then
            serverLauncher = launcher
            printColored("✓ Server launcher available", colors.green)
        else
            printColored("⚠ Server launcher failed to load: " .. tostring(launcher), colors.yellow)
        end
    else
        printColored("⚠ Server launcher not found (/tests/servers/launcher.lua)", colors.yellow)
    end

    -- Try to load test client
    if fs.exists("/tests/test_client.lua") then
        local ok, client = pcall(dofile, "/tests/test_client.lua")
        if ok and client then
            testClient = client
            printColored("✓ Test client available", colors.green)
        else
            printColored("⚠ Test client failed to load: " .. tostring(client), colors.yellow)
        end
    else
        printColored("⚠ Test client not found (/tests/test_client.lua)", colors.yellow)
    end

    print("\nPress any key to continue...")
    os.pullEvent("key")
end

-- Check system status
local function checkSystemStatus()
    local status = {
        modem = peripheral.find("modem") ~= nil,
        netd = fs.exists("/var/run/netd.pid"),
        network_lib = fs.exists("/lib/network.lua"),
        protocols_dir = fs.exists("/protocols"),
        tests_dir = fs.exists("/tests"),
        basalt = pcall(require, "basalt"),
        rednet_open = rednet.isOpen()
    }

    printHeader("System Status Check")
    print()

    printColored("Core Components:", colors.cyan)
    printColored(string.format("  [%s] Modem Available",
            status.modem and "OK" or "FAIL"),
            status.modem and colors.green or colors.red)

    printColored(string.format("  [%s] Rednet Open",
            status.rednet_open and "OK" or "FAIL"),
            status.rednet_open and colors.green or colors.red)

    printColored(string.format("  [%s] Network Daemon (netd)",
            status.netd and "OK" or "FAIL"),
            status.netd and colors.green or colors.red)

    printColored(string.format("  [%s] Network Library",
            status.network_lib and "OK" or "FAIL"),
            status.network_lib and colors.green or colors.red)

    printColored(string.format("  [%s] Protocols Directory",
            status.protocols_dir and "OK" or "FAIL"),
            status.protocols_dir and colors.green or colors.red)

    printColored(string.format("  [%s] Tests Directory",
            status.tests_dir and "OK" or "FAIL"),
            status.tests_dir and colors.green or colors.red)

    printColored(string.format("  [%s] Basalt GUI Framework",
            status.basalt and "OK" or "FAIL"),
            status.basalt and colors.green or colors.red)

    print()
    printColored("Test Infrastructure:", colors.cyan)
    printColored(string.format("  [%s] Server Launcher",
            serverLauncher and "OK" or "NOT LOADED"),
            serverLauncher and colors.green or colors.yellow)

    printColored(string.format("  [%s] Test Client",
            testClient and "OK" or "NOT LOADED"),
            testClient and colors.green or colors.yellow)

    print()
    printColored("Protocol Availability:", colors.cyan)

    -- Check each protocol
    for _, proto in ipairs(PROTOCOLS) do
        local protocol_file = proto.protocol_file
        local test_file = proto.file
        local protocol_exists = fs.exists(protocol_file)
        local test_exists = fs.exists(test_file)

        local status_text = "Not Installed"
        local status_color = colors.red

        if protocol_exists and test_exists then
            status_text = "Ready"
            status_color = colors.green
        elseif protocol_exists then
            status_text = "No Test"
            status_color = colors.yellow
        elseif test_exists then
            status_text = "No Protocol"
            status_color = colors.orange
        end

        printColored(string.format("  %-12s: %s", proto.name, status_text), status_color)
    end

    print()
    return status
end

-- Create test directory if it doesn't exist
local function ensureTestDirectory()
    if not fs.exists("/tests") then
        fs.makeDir("/tests")
        printColored("Created /tests directory", colors.green)
    end
    if not fs.exists("/tests/servers") then
        fs.makeDir("/tests/servers")
        printColored("Created /tests/servers directory", colors.green)
    end
end

-- Create a basic test file for a protocol if it doesn't exist
local function createBasicTestFile(protocol)
    local protocol_file = protocol.protocol_file
    local testCode = string.format([[
-- test_%s.lua
-- Test script for %s protocol

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

    -- Check if protocol exists
    local protocol_file = "%s"
    if not fs.exists(protocol_file) then
        printColored("\nERROR: %s protocol not installed!", colors.red)
        print("Please install the protocol first.")
        print("Expected location: " .. protocol_file)
        return false
    end

    -- Load protocol
    local success, protocol_module = pcall(dofile, protocol_file)
    if not success then
        printColored("\nERROR: Failed to load %s protocol", colors.red)
        print("Error: " .. tostring(protocol_module))
        return false
    end

    printColored("\n%s protocol loaded successfully!", colors.green)

    -- Basic protocol validation
    if type(protocol_module) == "table" then
        printColored("Protocol appears to be a valid module", colors.green)

        -- List available functions if it's a table
        print("\nAvailable functions/properties:")
        local count = 0
        for key, value in pairs(protocol_module) do
            if type(value) == "function" then
                print("  " .. key .. "() - function")
            else
                print("  " .. key .. " - " .. type(value))
            end
            count = count + 1
        end

        if count == 0 then
            printColored("Warning: No functions or properties found", colors.yellow)
        else
            printColored("Found " .. count .. " properties/functions", colors.green)
        end
    else
        printColored("Protocol module type: " .. type(protocol_module), colors.yellow)
    end

    -- TODO: Add specific tests for %s protocol
    printColored("\nBasic validation completed", colors.green)
    print("Specific protocol tests not yet implemented.")
    print("Add protocol-specific tests to this file for comprehensive testing.")

    return true
end

-- Main test function
local function main()
    local success = test_%s()

    print("\nTest Result: " .. (success and "PASSED" or "FAILED"))
    print("\nPress any key to return to menu...")
    os.pullEvent("key")
end

main()
]], protocol.id, protocol.name, protocol.id, protocol.name,
            protocol_file, protocol.name, protocol.name, protocol.name, protocol.id)

    local file = fs.open(protocol.file, "w")
    if file then
        file.write(testCode)
        file.close()
        return true
    end
    return false
end

-- Run a protocol test
local function runProtocolTest(protocol)
    printHeader("Running " .. protocol.name .. " Test")

    -- Check if test file exists
    if not fs.exists(protocol.file) then
        print()
        printColored("Test file not found: " .. protocol.file, colors.yellow)
        print("\nWould you like to create a basic test file? (y/n)")
        local answer = read()

        if answer:lower() == "y" then
            if createBasicTestFile(protocol) then
                printColored("Created basic test file: " .. protocol.file, colors.green)
                print("\nPress any key to run the test...")
                os.pullEvent("key")
            else
                printColored("Failed to create test file", colors.red)
                print("\nPress any key to return...")
                os.pullEvent("key")
                return
            end
        else
            print("\nPress any key to return...")
            os.pullEvent("key")
            return
        end
    end

    -- Check if protocol exists
    local protocol_file = protocol.protocol_file
    if not fs.exists(protocol_file) then
        print()
        printColored("Warning: Protocol not installed: " .. protocol_file, colors.yellow)
        print("Test may fail without the protocol implementation.")
        print("\nContinue anyway? (y/n)")
        local answer = read()
        if answer:lower() ~= "y" then
            return
        end
    end

    -- Run the test
    print("\nStarting test...")
    sleep(1)

    -- Execute test file
    local success, error = pcall(function()
        shell.run(protocol.file)
    end)

    if not success then
        print()
        printColored("Test failed with error:", colors.red)
        print(error)
        print("\nPress any key to return...")
        os.pullEvent("key")
    end
end

-- Server management functions
local function manageServers()
    if not serverLauncher then
        printHeader("Server Management")
        printColored("Server launcher not available!", colors.red)
        print("Please ensure /tests/servers/launcher.lua exists and is working.")
        print("\nPress any key to return...")
        os.pullEvent("key")
        return
    end

    printHeader("Test Server Management")
    print()
    printColored("Available servers:", colors.cyan)

    local servers = serverLauncher.serverConfigs or {}
    for serverType, config in pairs(servers) do
        local statusColor = config.status == "running" and colors.green or colors.red
        printColored(string.format("  %-12s: %s (Port %d)",
                config.name, config.status, config.port), statusColor)
    end

    print()
    print("1. Start All Servers")
    print("2. Stop All Servers")
    print("3. Server Status")
    print("4. Launch Full GUI")
    print("5. Return to Main Menu")
    print()
    print("Enter your choice: ")

    local choice = read()

    if choice == "1" then
        print("Starting all servers...")
        for serverType, _ in pairs(servers) do
            local success, message = serverLauncher.startServer(serverType)
            local color = success and colors.green or colors.red
            printColored(servers[serverType].name .. ": " .. message, color)
        end
        print("\nPress any key to continue...")
        os.pullEvent("key")

    elseif choice == "2" then
        print("Stopping all servers...")
        for serverType, _ in pairs(servers) do
            local success, message = serverLauncher.stopServer(serverType)
            local color = success and colors.green or colors.red
            printColored(servers[serverType].name .. ": " .. message, color)
        end
        print("\nPress any key to continue...")
        os.pullEvent("key")

    elseif choice == "3" then
        printHeader("Server Status Details")
        for serverType, config in pairs(servers) do
            print()
            printColored(config.name .. ":", colors.cyan)
            local stats = serverLauncher.getServerStats(serverType)
            for key, value in pairs(stats) do
                print("  " .. key .. ": " .. tostring(value))
            end
        end
        print("\nPress any key to continue...")
        os.pullEvent("key")

    elseif choice == "4" then
        printColored("Launching server GUI...", colors.green)
        print("Note: This will exit the current menu.")
        print("Continue? (y/n)")
        local answer = read()
        if answer:lower() == "y" then
            shell.run("/tests/servers/launcher.lua")
        end

    elseif choice ~= "5" then
        printColored("Invalid choice. Please try again.", colors.red)
        sleep(1)
    end
end

-- Run comprehensive network tests
local function runComprehensiveTests()
    if not testClient then
        printHeader("Comprehensive Network Tests")
        printColored("Test client not available!", colors.red)
        print("Please ensure /tests/test_client.lua exists and is working.")
        print("\nPress any key to return...")
        os.pullEvent("key")
        return
    end

    printHeader("Running Comprehensive Network Tests")
    print("This will test HTTP, WebSocket, and UDP protocols")
    print("using the integrated test client.")
    print()
    print("Continue? (y/n)")

    local answer = read()
    if answer:lower() ~= "y" then
        return
    end

    print()
    printColored("Starting comprehensive tests...", colors.cyan)

    -- Run HTTP tests
    print("\n" .. string.rep("-", 40))
    printColored("Testing HTTP Protocol", colors.yellow)
    local httpResults = testClient.testHTTP()

    -- Run WebSocket tests
    print("\n" .. string.rep("-", 40))
    printColored("Testing WebSocket Protocol", colors.yellow)
    local wsResults = testClient.testWebSocket()

    -- Run UDP tests
    print("\n" .. string.rep("-", 40))
    printColored("Testing UDP Protocol", colors.yellow)
    local udpResults = testClient.testUDP()

    -- Display results summary
    print("\n" .. string.rep("=", 50))
    printColored("COMPREHENSIVE TEST RESULTS", colors.cyan)
    print(string.rep("=", 50))

    -- HTTP Results
    print("\nHTTP Tests:")
    if httpResults and #httpResults > 0 then
        for _, result in ipairs(httpResults) do
            local color = result.success and colors.green or colors.red
            local status = result.success and "PASS" or "FAIL"
            printColored("  " .. result.endpoint .. ": " .. status, color)
        end
    else
        printColored("  No HTTP results", colors.yellow)
    end

    -- WebSocket Results
    print("\nWebSocket Tests:")
    if wsResults and wsResults.error then
        printColored("  ERROR: " .. wsResults.error, colors.red)
    elseif wsResults and #wsResults > 0 then
        for _, result in ipairs(wsResults) do
            local color = result.success and colors.green or colors.red
            local status = result.success and "PASS" or "FAIL"
            printColored("  " .. result.command .. ": " .. status, color)
        end
    else
        printColored("  No WebSocket results", colors.yellow)
    end

    -- UDP Results
    print("\nUDP Tests:")
    if udpResults and udpResults.error then
        printColored("  ERROR: " .. udpResults.error, colors.red)
    elseif udpResults and #udpResults > 0 then
        for _, result in ipairs(udpResults) do
            local color = result.success and colors.green or colors.red
            local status = result.success and "PASS" or "FAIL"
            local desc = result.command or result.service
            printColored("  " .. desc .. ": " .. status, color)
        end
    else
        printColored("  No UDP results", colors.yellow)
    end

    print("\nPress any key to return to menu...")
    os.pullEvent("key")
end

-- Show main menu
local function showMainMenu()
    while true do
        printHeader("Network Protocol Test Suite")
        print()
        printColored("Select a protocol to test:", colors.cyan)
        print()

        -- Display protocol options
        for i, proto in ipairs(PROTOCOLS) do
            local protocol_file = proto.protocol_file
            local test_file = proto.file
            local status = ""

            if fs.exists(protocol_file) and fs.exists(test_file) then
                status = "[Ready]"
            elseif fs.exists(protocol_file) then
                status = "[No Test]"
            elseif fs.exists(test_file) then
                status = "[No Protocol]"
            else
                status = "[Not Available]"
            end

            print(string.format("%d. %-12s %s", i, proto.name, status))
        end

        print()
        printColored("Additional Options:", colors.cyan)
        print("S. System Status Check")
        print("A. Run All Available Tests")
        print("C. Create Missing Test Files")
        print("M. Manage Test Servers")
        print("T. Comprehensive Network Tests")
        print("G. Launch Test Client GUI")
        print("L. Load Test Components")
        print("Q. Quit")
        print()
        print("Enter your choice: ")

        local choice = read():lower()

        if choice == "q" then
            printHeader("Exiting Test Suite")
            print("\nThank you for testing!")
            break

        elseif choice == "s" then
            checkSystemStatus()
            print("\nPress any key to continue...")
            os.pullEvent("key")

        elseif choice == "a" then
            -- Run all available tests
            printHeader("Running All Available Tests")
            local testsRun = 0

            for _, proto in ipairs(PROTOCOLS) do
                local protocol_file = proto.protocol_file
                if fs.exists(proto.file) and fs.exists(protocol_file) then
                    print("\n" .. string.rep("-", 40))
                    print("Running " .. proto.name .. " test...")
                    runProtocolTest(proto)
                    testsRun = testsRun + 1
                end
            end

            if testsRun == 0 then
                printColored("\nNo tests available to run!", colors.yellow)
                print("Use option 'C' to create missing test files first.")
                print("\nPress any key to continue...")
                os.pullEvent("key")
            else
                print("\n" .. string.rep("=", 40))
                printColored("Completed " .. testsRun .. " tests", colors.green)
                print("\nPress any key to continue...")
                os.pullEvent("key")
            end

        elseif choice == "c" then
            -- Create missing test files
            printHeader("Creating Missing Test Files")
            local created = 0

            for _, proto in ipairs(PROTOCOLS) do
                if not fs.exists(proto.file) then
                    print("Creating " .. proto.file .. "...")
                    if createBasicTestFile(proto) then
                        printColored("  Created", colors.green)
                        created = created + 1
                    else
                        printColored("  Failed", colors.red)
                    end
                end
            end

            if created > 0 then
                printColored("\nCreated " .. created .. " test files", colors.green)
            else
                printColored("\nNo test files needed to be created", colors.yellow)
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
                print("Note: This will exit the current menu.")
                print("Continue? (y/n)")
                local answer = read()
                if answer:lower() == "y" then
                    shell.run("/tests/test_client.lua")
                end
            else
                printColored("Test client not available!", colors.red)
                print("Use option 'L' to try loading test components.")
                print("\nPress any key to continue...")
                os.pullEvent("key")
            end

        elseif choice == "l" then
            loadTestComponents()

        else
            -- Try to parse as number for protocol selection
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

-- Main program
local function main()
    -- Ensure test directory exists
    ensureTestDirectory()

    -- Check for critical components
    if not peripheral.find("modem") then
        printHeader("Critical Error")
        printColored("\nNo modem found!", colors.red)
        print("Network testing requires a modem.")
        print("\nPlease attach a modem and try again.")
        return
    end

    -- Show welcome message
    printHeader("Welcome to Network Protocol Test Suite")
    print()
    print("This suite allows you to test various network")
    print("protocols implemented in the CC Networking system.")
    print()
    print("Features:")
    print("• Protocol testing with auto-generated test files")
    print("• Test server management and control")
    print("• Comprehensive network testing")
    print("• Integration with Basalt GUI components")
    print("• System status monitoring")
    print()
    printColored("Press any key to continue...", colors.cyan)
    os.pullEvent("key")

    -- Try to load test components automatically
    loadTestComponents()

    -- Run main menu
    showMainMenu()
end

-- Run the test suite
main()