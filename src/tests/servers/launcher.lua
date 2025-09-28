-- /tests/servers/launcher.lua
-- Test Server Launcher for ComputerCraft Network System
-- Manages and launches various test servers with Basalt UI

local basalt = require("basalt")

local launcher = {}
launcher.version = "1.0.0"
launcher.servers = {}
launcher.running = true

-- Available test servers
local serverConfigs = {
    http = {
        name = "HTTP Server",
        file = "/tests/servers/http_server.lua",
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
local function log(message, level)
    level = level or "INFO"
    local timestamp = os.date("%H:%M:%S")
    local logEntry = string.format("[%s] %s: %s", timestamp, level, message)
    print(logEntry)

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

    -- Load and start the server
    local ok, serverModule = pcall(dofile, config.file)
    if not ok then
        log("Failed to load " .. config.name .. ": " .. serverModule, "ERROR")
        return false, "Failed to load server: " .. serverModule
    end

    if serverModule and serverModule.start then
        local success = serverModule.start()
        if success then
            config.status = "running"
            config.instance = serverModule
            log("Started " .. config.name .. " on port " .. config.port)
            return true, "Server started successfully"
        else
            return false, "Server failed to start"
        end
    else
        return false, "Invalid server module"
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

    if config.instance and config.instance.stop then
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
        config.status = "stopped"
        config.instance = nil
        return true, "Server marked as stopped"
    end
end

local function getServerStats(serverType)
    local config = serverConfigs[serverType]
    if not config or not config.instance then
        return {
            running = false,
            error = "Server not available"
        }
    end

    if config.instance.getStats then
        return config.instance.getStats()
    else
        return {
            running = config.status == "running",
            message = "No statistics available"
        }
    end
end

-- UI Creation
local main, statusLabel, logList

local function updateServerStatus()
    -- Update server status in UI
    for serverType, config in pairs(serverConfigs) do
        local statusText = string.format("%s: %s (Port %d)",
                config.name, config.status, config.port)
        -- Update UI elements (you'd need to track the specific labels)
    end
end

local function addLogMessage(message, color)
    if logList then
        logList:addItem(string.format("[%s] %s", os.date("%H:%M:%S"), message), color or colors.white)
        if logList.scrollToBottom then
            logList:scrollToBottom()
        end
    end
end

local function createMainUI()
    local w, h = term.getSize()
    main = basalt.getMainFrame():setBackground(colors.blue):setSize(w, h)

    -- Title
    main:addLabel():setPosition(1, 1):setSize(w, 1)
        :setText("ComputerCraft Network Test Server Launcher v" .. launcher.version)
        :setForeground(colors.white):setBackground(colors.blue)

    -- Server control panel
    local controlPanel = main:addFrame():setPosition(2, 3):setSize(w-2, 12):setBackground(colors.white)
    controlPanel:addLabel():setPosition(1, 1):setText("Server Control Panel"):setForeground(colors.black)

    local yPos = 3
    for serverType, config in pairs(serverConfigs) do
        -- Server name and status
        controlPanel:addLabel():setPosition(1, yPos):setSize(20, 1)
                    :setText(config.name):setForeground(colors.black)

        local statusColor = config.status == "running" and colors.green or colors.red
        controlPanel:addLabel():setPosition(21, yPos):setSize(10, 1)
                    :setText(config.status):setForeground(statusColor)

        -- Control buttons
        local startBtn = controlPanel:addButton():setPosition(32, yPos):setSize(6, 1)
                                     :setText("Start"):setBackground(colors.green):setForeground(colors.white)

        local stopBtn = controlPanel:addButton():setPosition(39, yPos):setSize(6, 1)
                                    :setText("Stop"):setBackground(colors.red):setForeground(colors.white)

        local statsBtn = controlPanel:addButton():setPosition(46, yPos):setSize(6, 1)
                                     :setText("Stats"):setBackground(colors.orange):setForeground(colors.white)

        -- Button event handlers
        startBtn:onClick(function()
            local success, message = startServer(serverType)
            local color = success and colors.green or colors.red
            addLogMessage(config.name .. ": " .. message, color)
            updateServerStatus()
        end)

        stopBtn:onClick(function()
            local success, message = stopServer(serverType)
            local color = success and colors.green or colors.red
            addLogMessage(config.name .. ": " .. message, color)
            updateServerStatus()
        end)

        statsBtn:onClick(function()
            local stats = getServerStats(serverType)
            if stats.running then
                local statsMsg = string.format("%s Stats - Uptime: %ds",
                        config.name, stats.uptime or 0)
                addLogMessage(statsMsg, colors.cyan)
            else
                addLogMessage(config.name .. ": Not running", colors.yellow)
            end
        end)

        yPos = yPos + 1
    end

    -- Action buttons
    local startAllBtn = controlPanel:addButton():setPosition(1, yPos + 1):setSize(12, 1)
                                    :setText("Start All"):setBackground(colors.lime):setForeground(colors.black)

    local stopAllBtn = controlPanel:addButton():setPosition(14, yPos + 1):setSize(12, 1)
                                   :setText("Stop All"):setBackground(colors.pink):setForeground(colors.black)

    local testBtn = controlPanel:addButton():setPosition(27, yPos + 1):setSize(12, 1)
                                :setText("Run Tests"):setBackground(colors.cyan):setForeground(colors.black)

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
    local logPanel = main:addFrame():setPosition(2, 16):setSize(w-2, h-16):setBackground(colors.black)
    logPanel:addLabel():setPosition(1, 1):setText("Server Logs"):setForeground(colors.white)

    logList = logPanel:addList():setPosition(1, 2):setSize(w-2, h-18)
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

-- Network status check
local function checkNetworkStatus()
    local networkOk = true
    local issues = {}

    -- Check if netd is running
    if not fs.exists("/var/run/netd.pid") then
        table.insert(issues, "netd not running")
        networkOk = false
    end

    -- Check if rednet is open
    if not rednet.isOpen() then
        table.insert(issues, "rednet not open")
        networkOk = false
    end

    -- Check UDP protocol availability
    if not _G.netd_udp and not fs.exists("/protocols/udp.lua") then
        table.insert(issues, "UDP protocol not available")
    end

    return networkOk, issues
end

-- Startup checks
local function performStartupChecks()
    addLogMessage("Performing startup checks...", colors.yellow)

    -- Check network status
    local networkOk, issues = checkNetworkStatus()
    if networkOk then
        addLogMessage("Network status: OK", colors.green)
    else
        addLogMessage("Network issues: " .. table.concat(issues, ", "), colors.red)
    end

    -- Check server files
    local filesOk = true
    for serverType, config in pairs(serverConfigs) do
        if fs.exists(config.file) then
            addLogMessage(config.name .. " file: OK", colors.green)
        else
            addLogMessage(config.name .. " file: MISSING (" .. config.file .. ")", colors.red)
            filesOk = false
        end
    end

    if filesOk and networkOk then
        addLogMessage("All startup checks passed", colors.lime)
    else
        addLogMessage("Some startup checks failed - functionality may be limited", colors.orange)
    end
end

-- Main execution
local function main_loop()
    createMainUI()
    performStartupChecks()

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

-- Auto-start UI if run directly
if not _G.server_launcher then
    _G.server_launcher = launcher
    main_loop()
end

return launcher