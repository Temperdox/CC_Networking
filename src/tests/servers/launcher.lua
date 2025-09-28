-- /tests/servers/launcher.lua
-- Test Server Launcher for ComputerCraft Network System
-- Fixed version that works with bridge loader

local basalt = nil

-- Check for pre-loaded basalt from test_network
if _G._test_network_basalt then
    basalt = _G._test_network_basalt
elseif _G._launcher_basalt then
    basalt = _G._launcher_basalt
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

-- If no basalt, create stub functions for non-GUI mode
local hasBasalt = basalt ~= nil

local launcher = {}
launcher.version = "1.0.0"
launcher.servers = {}
launcher.running = true

-- Available test servers
local serverConfigs = {
    http = {
        name = "HTTP Server",
        file = "/tests/servers/http_test_server.lua",
        port = 8080,
        description = "HTTP server with Basalt XML responses",
        status = "stopped",
        instance = nil
    },
    websocket = {
        name = "WebSocket Server",
        file = "/tests/servers/websocket_server.lua",
        port = 8081,
        description = "WebSocket server for real-time communication",
        status = "stopped",
        instance = nil
    },
    udp = {
        name = "UDP Server",
        file = "/tests/servers/udp_server.lua",
        port = 12345,
        description = "UDP server with echo, time, and custom services",
        status = "stopped",
        instance = nil
    }
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

    -- Console output in non-GUI mode
    if not hasBasalt then
        print(logEntry)
    end

    if not fs.exists("/var/log") then fs.makeDir("/var/log") end
    local logFile = fs.open("/var/log/server_launcher.log", "a")
    if logFile then
        logFile.writeLine(logEntry)
        logFile.close()
    end
end

-- Server management functions
local function startServer(serverType)
    local config = serverConfigs[serverType]
    if not config then
        return false, "Unknown server type"
    end

    if config.status == "running" then
        return false, "Server already running"
    end

    if not fs.exists(config.file) then
        return false, "Server file not found: " .. config.file
    end

    -- Set a flag so servers know they're being launched
    _G.server_launcher = launcher

    -- Load and start the server in a coroutine
    local ok, err = pcall(function()
        local serverModule = dofile(config.file)
        if type(serverModule) == "table" and serverModule.start then
            local success = serverModule.start()
            if success then
                config.status = "running"
                config.instance = serverModule
                log("Started " .. config.name .. " on port " .. config.port)
                return true
            end
        elseif type(serverModule) == "function" then
            -- Try running it as a function
            config.status = "running"
            config.instance = {running = true}
            log("Started " .. config.name .. " on port " .. config.port)
            return true
        end
    end)

    if ok then
        return true, "Server started successfully"
    else
        log("Failed to start " .. config.name .. ": " .. tostring(err), "ERROR")
        return false, "Failed to start: " .. tostring(err)
    end
end

local function stopServer(serverType)
    local config = serverConfigs[serverType]
    if not config then
        return false, "Unknown server type"
    end

    if config.status == "stopped" then
        return false, "Server not running"
    end

    if config.instance and type(config.instance) == "table" and config.instance.stop then
        local success = config.instance.stop()
        if success then
            config.status = "stopped"
            config.instance = nil
            log("Stopped " .. config.name)
            return true, "Server stopped successfully"
        else
            return false, "Failed to stop server"
        end
    else
        -- Force stop
        config.status = "stopped"
        config.instance = nil
        log("Force stopped " .. config.name)
        return true, "Server marked as stopped"
    end
end

local function getServerStats(serverType)
    local config = serverConfigs[serverType]
    if not config then
        return {
            running = false,
            error = "Server not available"
        }
    end

    local stats = {
        running = config.status == "running",
        port = config.port,
        description = config.description
    }

    if config.instance and type(config.instance) == "table" and config.instance.getStats then
        local customStats = config.instance.getStats()
        for k, v in pairs(customStats) do
            stats[k] = v
        end
    end

    return stats
end

-- GUI Mode Functions (only if Basalt is available)
local main, statusLabel, logList

local function addLogMessage(message, color)
    if hasBasalt and logList then
        logList:addItem(message):setForeground(color or colors.white)
        logList:scrollToBottom()
    else
        log(message)
    end
end

local function updateServerStatus()
    if not hasBasalt then return end

    -- Update server status in UI
    for serverType, config in pairs(serverConfigs) do
        local statusText = string.format("%s: %s", config.name, config.status)
        if statusLabel then
            statusLabel:setText(statusText)
        end
    end
end

local function createMainUI()
    if not hasBasalt then
        log("Basalt not available - running in console mode", "INFO")
        return
    end

    local w, h = term.getSize()
    main = basalt.getMainFrame():setBackground(colors.blue):setSize(w, h)

    -- Title
    main:addLabel():setPosition(1, 1):setSize(w, 1)
        :setText("CC Network Test Server Launcher v" .. launcher.version)
        :setForeground(colors.white):setBackground(colors.blue)

    -- Server status panel
    local statusPanel = main:addFrame():setPosition(2, 3):setSize(w-2, 10):setBackground(colors.white)
    statusPanel:addLabel():setPosition(1, 1):setText("Server Status"):setForeground(colors.black)

    local y = 3
    for serverType, config in pairs(serverConfigs) do
        local serverFrame = statusPanel:addFrame():setPosition(1, y):setSize(w-4, 2):setBackground(colors.lightGray)

        serverFrame:addLabel():setPosition(2, 1):setText(config.name):setForeground(colors.black)

        local statusText = config.status == "running" and "Running" or "Stopped"
        local statusColor = config.status == "running" and colors.green or colors.red

        local statusLabel = serverFrame:addLabel():setPosition(20, 1):setText(statusText)
                                       :setForeground(statusColor)

        local startBtn = serverFrame:addButton():setPosition(30, 1):setSize(8, 1)
                                    :setText("Start"):setBackground(colors.green):setForeground(colors.white)

        local stopBtn = serverFrame:addButton():setPosition(39, 1):setSize(8, 1)
                                   :setText("Stop"):setBackground(colors.red):setForeground(colors.white)

        startBtn:onClick(function()
            local success, message = startServer(serverType)
            local color = success and colors.green or colors.red
            addLogMessage("Start " .. config.name .. ": " .. message, color)
            statusLabel:setText(serverConfigs[serverType].status == "running" and "Running" or "Stopped")
                       :setForeground(serverConfigs[serverType].status == "running" and colors.green or colors.red)
        end)

        stopBtn:onClick(function()
            local success, message = stopServer(serverType)
            local color = success and colors.green or colors.red
            addLogMessage("Stop " .. config.name .. ": " .. message, color)
            statusLabel:setText(serverConfigs[serverType].status == "running" and "Running" or "Stopped")
                       :setForeground(serverConfigs[serverType].status == "running" and colors.green or colors.red)
        end)

        y = y + 2
    end

    -- Control buttons
    local controlPanel = statusPanel:addFrame():setPosition(1, 9):setSize(w-4, 2):setBackground(colors.white)

    local startAllBtn = controlPanel:addButton():setPosition(2, 1):setSize(15, 1)
                                    :setText("Start All"):setBackground(colors.green):setForeground(colors.white)

    local stopAllBtn = controlPanel:addButton():setPosition(18, 1):setSize(15, 1)
                                   :setText("Stop All"):setBackground(colors.red):setForeground(colors.white)

    local testBtn = controlPanel:addButton():setPosition(34, 1):setSize(12, 1)
                                :setText("Test"):setBackground(colors.orange):setForeground(colors.white)

    startAllBtn:onClick(function()
        for serverType, _ in pairs(serverConfigs) do
            local success, message = startServer(serverType)
            local color = success and colors.green or colors.red
            addLogMessage("Start " .. serverConfigs[serverType].name .. ": " .. message, color)
        end
        updateServerStatus()
    end)

    stopAllBtn:onClick(function()
        for serverType, _ in pairs(serverConfigs) do
            local success, message = stopServer(serverType)
            local color = success and colors.green or colors.red
            addLogMessage("Stop " .. serverConfigs[serverType].name .. ": " .. message, color)
        end
        updateServerStatus()
    end)

    testBtn:onClick(function()
        addLogMessage("Running server tests...", colors.yellow)
        -- Run basic connectivity tests
        for serverType, config in pairs(serverConfigs) do
            if config.status == "running" and config.instance and config.instance.test then
                config.instance.test()
                addLogMessage(config.name .. " test completed", colors.green)
            end
        end
    end)

    -- Log panel
    local logPanel = main:addFrame():setPosition(2, 14):setSize(w-2, h-15):setBackground(colors.black)
    logPanel:addLabel():setPosition(1, 1):setText("Server Logs"):setForeground(colors.white)

    logList = logPanel:addList():setPosition(1, 2):setSize(w-2, h-17)
                      :setBackground(colors.black):setForeground(colors.white)

    -- Exit button
    local exitBtn = main:addButton():setPosition(w-8, h):setSize(8, 1)
                        :setText("Exit"):setBackground(colors.red):setForeground(colors.white)

    exitBtn:onClick(function()
        launcher.running = false
    end)

    -- Initial log message
    addLogMessage("Server Launcher initialized", colors.lime)
    addLogMessage("Computer ID: " .. os.getComputerID(), colors.cyan)
end

-- Console mode menu
local function consoleMenu()
    while launcher.running do
        term.clear()
        term.setCursorPos(1, 1)
        print("=== CC Network Test Server Launcher ===")
        print("")
        print("Server Status:")
        for serverType, config in pairs(serverConfigs) do
            local status = config.status == "running" and "[RUNNING]" or "[STOPPED]"
            print(string.format("  %s %s (Port %d)", status, config.name, config.port))
        end

        print("")
        print("Commands:")
        print("1-3: Toggle server (HTTP/WebSocket/UDP)")
        print("A: Start all servers")
        print("S: Stop all servers")
        print("L: Show logs")
        print("Q: Quit")
        print("")
        write("Choice: ")

        local choice = string.upper(read())

        if choice == "Q" then
            launcher.running = false
        elseif choice == "A" then
            for serverType, _ in pairs(serverConfigs) do
                startServer(serverType)
            end
        elseif choice == "S" then
            for serverType, _ in pairs(serverConfigs) do
                stopServer(serverType)
            end
        elseif choice == "L" then
            term.clear()
            term.setCursorPos(1, 1)
            print("=== Recent Logs ===")
            for i = math.max(1, #logMessages - 15), #logMessages do
                if logMessages[i] then
                    print(string.format("[%s] %s", logMessages[i].time, logMessages[i].message))
                end
            end
            print("\nPress any key to continue...")
            os.pullEvent("key")
        else
            local num = tonumber(choice)
            if num and num >= 1 and num <= 3 then
                local types = {"http", "websocket", "udp"}
                local serverType = types[num]
                if serverConfigs[serverType].status == "running" then
                    stopServer(serverType)
                else
                    startServer(serverType)
                end
            end
        end
    end
end

-- Main execution
local function main_loop()
    if hasBasalt then
        createMainUI()
        log("Running in GUI mode with Basalt", "INFO")

        while launcher.running do
            local event = {os.pullEventRaw()}
            basalt.update(table.unpack(event))

            if event[1] == "terminate" then
                -- Stop all servers before exiting
                for serverType, _ in pairs(serverConfigs) do
                    if serverConfigs[serverType].status == "running" then
                        stopServer(serverType)
                    end
                end
                launcher.running = false
            end
        end
    else
        log("Running in console mode", "INFO")
        consoleMenu()
    end

    -- Clean exit
    term.clear()
    term.setCursorPos(1, 1)
    print("Server Launcher exited.")
end

-- Export functions for external use
launcher.startServer = startServer
launcher.stopServer = stopServer
launcher.getServerStats = getServerStats
launcher.serverConfigs = serverConfigs

-- Check if being loaded by test_network or run directly
if not (_G.server_launcher or _G._test_network_basalt) then
    -- Running directly
    main_loop()
else
    -- Being loaded as a module
    _G.server_launcher = launcher
end

return launcher