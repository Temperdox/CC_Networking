-- /tests/test_network.lua
-- Main network protocol testing menu system - Bridge Version
-- Acts as a loader to prevent library conflicts in sandbox environment

local function printHeader(text)
    term.clear()
    term.setCursorPos(1, 1)
    print(string.rep("=", 50))
    print("  " .. text)
    print(string.rep("=", 50))
end

local function printColored(text, color)
    if term.isColor and term.isColor() and color and type(color) == "number" then
        local old = term.getTextColor and term.getTextColor() or colors.white
        term.setTextColor(color)
        print(text)
        term.setTextColor(old)
    else
        print(text)
    end
end

-- Protocol definitions with correct file paths
local PROTOCOLS = {
    {id = "websocket",   name = "WebSocket", file = "/tests/test_websocket.lua", protocol_file = "/protocols/websocket.lua"},
    {id = "http_client", name = "HTTP",      file = "/tests/test_http.lua",      protocol_file = "/protocols/http_client.lua"},
    {id = "https",       name = "HTTPS",     file = "/tests/test_https.lua",     protocol_file = "/protocols/https.lua"},
    {id = "webrtc",      name = "WebRTC",    file = "/tests/test_webrtc.lua",    protocol_file = "/protocols/webrtc.lua"},
    {id = "tcp",         name = "TCP",       file = "/tests/test_tcp.lua",       protocol_file = "/protocols/tcp.lua"},
    {id = "udp",         name = "UDP",       file = "/tests/test_udp.lua",       protocol_file = "/protocols/udp.lua"},
    {id = "mqtt",        name = "MQTT",      file = "/tests/test_mqtt.lua",      protocol_file = "/protocols/mqtt.lua"},
    {id = "ftp",         name = "FTP",       file = "/tests/test_ftp.lua",       protocol_file = "/protocols/ftp.lua"},
    {id = "ssh",         name = "SSH",       file = "/tests/test_ssh.lua",       protocol_file = "/protocols/ssh.lua"},
}

-- Global state for test components
local serverLauncher = nil
local testClient = nil
local basaltLoaded = false
local basalt = nil

-- Ensure required directories exist
local function ensureDirectories()
    local dirs = {"/tests", "/tests/servers", "/var/log", "/var/run"}
    for _, dir in ipairs(dirs) do
        if not fs.exists(dir) then fs.makeDir(dir) end
    end
end

-- Load Basalt once for all components
local function loadBasalt()
    if basaltLoaded then return basalt end
    if fs.exists("basalt.lua") then
        local ok, mod = pcall(require, "basalt")
        if ok and mod then
            basalt = mod
            basaltLoaded = true
            _G._test_network_basalt = basalt
            return basalt
        end
    end
    return nil
end

-- Proper silent terminal (safe for BIOS): getters return valid values; writers are no-ops
local function makeSilentTerm(base)
    base = base or term
    local function noop() end
    local st = {}

    -- writers / mutators
    st.write = noop
    st.blit = noop
    st.clear = noop
    st.clearLine = noop
    st.setCursorPos = noop
    st.setCursorBlink = noop
    st.scroll = noop
    st.setTextColor = noop
    st.setBackgroundColor = noop

    -- getters (return sane values)
    st.getSize = function()
        if base and base.getSize then return base.getSize() end
        return 51, 19
    end
    st.getCursorPos = function() return 1, 1 end
    st.isColor = function() return base and base.isColor and base.isColor() or false end
    st.getTextColor = function()
        if base and base.getTextColor then return base.getTextColor() end
        return colors.white
    end
    st.getBackgroundColor = function()
        if base and base.getBackgroundColor then return base.getBackgroundColor() end
        return colors.black
    end

    return st
end

-- Load test components safely
local function loadTestComponents()
    printHeader("Loading Test Components")

    -- Load Basalt first if available
    local basaltInstance = loadBasalt()
    if basaltInstance then
        printColored("Basalt framework: OK", colors.green)
    else
        printColored("Basalt framework: Not available", colors.yellow)
    end

    serverLauncher, testClient = nil, nil

    -- Try to load server launcher
    if fs.exists("/tests/servers/launcher.lua") then
        local oldRequire = _G.require
        if basaltLoaded then
            _G.require = function(lib)
                if lib == "basalt" then return basalt end
                return oldRequire(lib)
            end
        end

        local ok, res = pcall(dofile, "/tests/servers/launcher.lua")
        _G.require = oldRequire

        if ok then
            if type(res) == "table" then
                serverLauncher = res
            elseif _G.server_launcher then
                serverLauncher = _G.server_launcher
            end
            if serverLauncher then
                printColored("Server launcher: OK", colors.green)
            else
                printColored("Server launcher: Invalid return", colors.yellow)
            end
        else
            printColored("Server launcher: Failed to load", colors.yellow)
            if res then print("Error: " .. tostring(res)) end
        end
    else
        printColored("Server launcher: Not found", colors.gray)
    end

    -- Try to load test client
    if fs.exists("/tests/test_client.lua") then
        local oldRequire = _G.require
        if basaltLoaded then
            _G.require = function(lib)
                if lib == "basalt" then return basalt end
                return oldRequire(lib)
            end
        end

        local ok, res = pcall(dofile, "/tests/test_client.lua")
        _G.require = oldRequire

        if ok then
            if type(res) == "table" then
                testClient = res
            elseif _G.network_test_client then
                testClient = _G.network_test_client
            end
            if testClient then
                printColored("Test client: OK", colors.green)
            else
                printColored("Test client: Invalid return", colors.yellow)
            end
        else
            printColored("Test client: Failed to load", colors.yellow)
            if res then print("Error: " .. tostring(res)) end
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

    printColored("System Components:", colors.cyan)

    local modem = peripheral.find("modem")
    printColored(string.format("  Modem: %s", modem and "OK" or "FAIL"), modem and colors.green or colors.red)

    local rednetOpen = rednet.isOpen()
    printColored(string.format("  Rednet: %s", rednetOpen and "Open" or "Closed"), rednetOpen and colors.green or colors.yellow)

    print()
    printColored("Network Infrastructure:", colors.cyan)

    local netd = fs.exists("/var/run/netd.pid")
    printColored(string.format("  Network Daemon: %s", netd and "Running" or "Stopped"), netd and colors.green or colors.red)

    local networkLib = fs.exists("/lib/network.lua")
    printColored(string.format("  Network Library: %s", networkLib and "OK" or "Missing"), networkLib and colors.green or colors.yellow)

    local protocolsDir = fs.exists("/protocols")
    printColored(string.format("  Protocols Directory: %s", protocolsDir and "OK" or "Missing"), protocolsDir and colors.green or colors.red)

    local basaltFile = fs.exists("basalt.lua")
    printColored(string.format("  Basalt Framework: %s", basaltFile and "OK" or "Missing"), basaltFile and colors.green or colors.yellow)

    print()
    printColored("Test Infrastructure:", colors.cyan)
    printColored(string.format("  Server Launcher: %s", serverLauncher and "Loaded" or "Not Available"), serverLauncher and colors.green or colors.yellow)
    printColored(string.format("  Test Client: %s", testClient and "Loaded" or "Not Available"), testClient and colors.green or colors.yellow)

    print("\nPress any key to continue...")
    os.pullEvent("key")
end

-- Test individual protocol
local function testProtocol(protocol)
    printHeader("Testing " .. protocol.name .. " Protocol")

    if not fs.exists(protocol.file) then
        printColored("Test file not found: " .. protocol.file, colors.red)
        print("\nWould you like to create a basic test file? (y/n)")
        local answer = (read() or ""):lower()
        if answer == "y" then
            local content = string.format([[-- Basic %s test
local ok, proto = pcall(dofile, %q)
if ok and proto then
    print("Protocol loaded successfully")
else
    print("Failed to load protocol: " .. tostring(proto))
end
]], protocol.name, protocol.protocol_file)
            local f = fs.open(protocol.file, "w"); f.write(content); f.close()
            printColored("Test file created successfully!", colors.green)
            print("\nRunning test..."); sleep(1)
        else
            return
        end
    end

    if not fs.exists(protocol.protocol_file) then
        printColored("Warning: Protocol file not found!", colors.yellow)
        print("Location: " .. protocol.protocol_file)
        print("Test may fail without the protocol.")
        print("\nContinue anyway? (y/n)")
        if (read() or ""):lower() ~= "y" then return end
    end

    print("\nExecuting test...")
    local ok, err = pcall(function() shell.run(protocol.file) end)
    if not ok then
        print("\nTest execution failed!")
        printColored("Error: " .. tostring(err), colors.red)
        print("\nPress any key to return...")
        os.pullEvent("key")
    end
end

-- Server management interface
local function manageServers()
    if not serverLauncher then
        printHeader("Server Management")
        printColored("Server launcher not available!", colors.red)
        print("\nOptions:\n1. Try to load server launcher\n2. Return to main menu\n\nChoice: ")
        if read() == "1" then loadTestComponents() end
        return
    end

    printHeader("Test Server Management")

    local servers = serverLauncher.serverConfigs or {}
    if next(servers) == nil then
        printColored("No servers configured!", colors.yellow)
        print("\nPress any key to return..."); os.pullEvent("key"); return
    end

    print("\nServer Status:")
    for _, cfg in pairs(servers) do
        local status = cfg.status or "unknown"
        local color = status == "running" and colors.green or colors.red
        printColored(string.format("  %-15s: %s (Port %d)", cfg.name or "server", status, cfg.port or 0), color)
    end

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
        for k, cfg in pairs(servers) do
            local ok, msg = serverLauncher.startServer(k)
            printColored(string.format("%s: %s", cfg.name, msg or "Unknown result"), ok and colors.green or colors.red)
        end
    elseif choice == "2" then
        print("\nStopping all servers...")
        for k, cfg in pairs(servers) do
            local ok, msg = serverLauncher.stopServer(k)
            printColored(string.format("%s: %s", cfg.name, msg or "Unknown result"), ok and colors.green or colors.red)
        end
    elseif choice == "3" then
        printHeader("Server Details")
        for k, cfg in pairs(servers) do
            print("\n" .. string.rep("-", 30))
            printColored(cfg.name or k, colors.cyan)
            local stats = serverLauncher.getServerStats and serverLauncher.getServerStats(k) or {}
            for key, value in pairs(stats) do
                print(string.format("  %s: %s", key, tostring(value)))
            end
        end
    elseif choice == "4" then
        printColored("Launching server management GUI...", colors.green)
        print("This will exit the current menu.\nContinue? (y/n)")
        if (read() or ""):lower() == "y" then
            if basaltLoaded then _G._launcher_basalt = basalt end
            shell.run("/tests/servers/launcher.lua")
            return
        end
    end

    if choice ~= "5" then
        print("\nPress any key to continue..."); os.pullEvent("key")
    end
end

-- Comprehensive network testing
local function runComprehensiveTests()
    if not testClient then
        printHeader("Comprehensive Network Tests")
        printColored("Test client not available!", colors.red)
        print("\nThe comprehensive test requires the test client.")
        print("Try loading test components first (option L).")
        print("\nPress any key to return..."); os.pullEvent("key")
        return
    end

    printHeader("Comprehensive Network Testing")
    print("This will run tests for HTTP, WebSocket, and UDP protocols")
    print("using the integrated test client.\n")
    print("Note: Make sure test servers are running first.\n")
    print("Continue? (y/n)")
    if (read() or ""):lower() ~= "y" then return end

    print("\nRunning comprehensive tests...")
    if testClient.runAllTests then
        local results = testClient.runAllTests()
        print("\n" .. string.rep("-", 40))
        print("Test Results Summary:")
        print(string.rep("-", 40))
        for protocol, tests in pairs(results) do
            local passed, total = 0, #tests
            for _, t in ipairs(tests) do if t.success then passed = passed + 1 end end
            local col = passed == total and colors.green or (passed > 0 and colors.yellow or colors.red)
            printColored(string.format("%-12s: %d/%d passed", protocol:upper(), passed, total), col)
        end
    else
        printColored("Test client doesn't support comprehensive testing", colors.red)
    end

    print("\nPress any key to continue..."); os.pullEvent("key")
end

-- Main menu
local function mainMenu()
    while true do
        printHeader("Network Protocol Testing System")
        print("\nSelect a test option:\n")

        printColored("Protocol Tests:", colors.cyan)
        for i, p in ipairs(PROTOCOLS) do
            print(string.format("%d. Test %s", i, p.name))
        end

        print()
        printColored("Management Options:", colors.cyan)
        print("S. System Status")
        print("M. Manage Test Servers")
        print("C. Comprehensive Testing")
        print("L. Load Test Components")
        print("Q. Quit")
        print("\nChoice: ")

        local choice = string.upper(read() or "")
        if choice == "Q" then
            break
        elseif choice == "S" then
            checkSystemStatus()
        elseif choice == "M" then
            manageServers()
        elseif choice == "C" then
            runComprehensiveTests()
        elseif choice == "L" then
            loadTestComponents()
        else
            local num = tonumber(choice)
            if num and num >= 1 and num <= #PROTOCOLS then
                testProtocol(PROTOCOLS[num])
            else
                printColored("Invalid choice!", colors.red)
                sleep(1)
            end
        end
    end

    term.clear()
    term.setCursorPos(1, 1)
    print("Network testing complete.")
end

-- Main execution
ensureDirectories()

print("Initializing Network Test System...")
if fs.exists("basalt.lua") then loadBasalt() end

-- OPTIONAL “silent” preload. Set SILENT_PRELOAD=false to show output.
local SILENT_PRELOAD = false
if fs.exists("/tests/servers/launcher.lua") and fs.exists("/tests/test_client.lua") then
    if SILENT_PRELOAD then
        local old = term.current()
        local silent = makeSilentTerm(old)
        term.redirect(silent)
        pcall(loadTestComponents)
        term.redirect(old)
    else
        -- just preload visibly (safe)
        loadTestComponents()
    end
end

-- Start main menu
mainMenu()
