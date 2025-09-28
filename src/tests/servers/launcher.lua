-- /tests/servers/launcher.lua
-- Test Server Launcher for ComputerCraft Network System
-- Manages and launches various test servers with Basalt UI

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

    -- Load and start the server (use dofile to keep global env)
    local ok, serverModule = pcall(dofile, config.file)
    if not ok then
        log("Failed to load " .. config.name .. ": " .. tostring(serverModule), "ERROR")
        return false, "Failed to load server: " .. tostring(serverModule)
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
        return { running = false, error = "Server not available" }
    end
    if config.instance.getStats then
        return config.instance.getStats()
    else
        return { running = config.status == "running", message = "No statistics available" }
    end
end

-- UI Creation
local main, statusLabel, logList

local function updateServerStatus()
    -- (kept simple; add per-server labels if you want live status lines)
end

local function addLogMessage(message, color)
    if logList then
        logList:addItem(string.format("[%s] %s", os.date("%H:%M:%S"), message), color or colors.white)
        if logList.scrollToBottom then logList:scrollToBottom() end
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
        controlPanel:addLabel():setPosition(1, yPos):setSize(20, 1)
                    :setText(config.name):setForeground(colors.black)

        local statusColor = config.status == "running" and colors.green or colors.red
        controlPanel:addLabel():setPosition(21, yPos):setSize(10, 1)
                    :setText(config.status):setForeground(statusColor)

        local startBtn = controlPanel:addButton():setPosition(32, yPos):setSize(6, 1)
                                     :setText("Start"):setBackground(colors.green):setForeground(colors.white)
        local stopBtn  = controlPanel:addButton():setPosition(39, yPos):setSize(6, 1)
                                     :setText("Stop"):setBackground(colors.red):setForeground(colors.white)
        local statsBtn = controlPanel:addButton():setPosition(46, yPos):setSize(6, 1)
                                     :setText("Stats"):setBackground(colors.orange):setForeground(colors.white)

        startBtn:onClick(function()
            local ok, msg = startServer(serverType)
            addLogMessage(config.name .. ": " .. msg, ok and colors.green or colors.red)
            updateServerStatus()
        end)
        stopBtn:onClick(function()
            local ok, msg = stopServer(serverType)
            addLogMessage(config.name .. ": " .. msg, ok and colors.green or colors.red)
            updateServerStatus()
        end)
        statsBtn:onClick(function()
            local st = getServerStats(serverType)
            if st.running then
                addLogMessage(string.format("%s uptime: %ds", config.name, st.uptime or 0), colors.cyan)
            else
                addLogMessage(config.name .. ": Not running", colors.yellow)
            end
        end)

        yPos = yPos + 1
    end

    -- Action buttons
    local startAllBtn = controlPanel:addButton():setPosition(1, yPos + 1):setSize(12, 1)
                                    :setText("Start All"):setBackground(colors.lime):setForeground(colors.black)
    local stopAllBtn  = controlPanel:addButton():setPosition(14, yPos + 1):setSize(12, 1)
                                    :setText("Stop All"):setBackground(colors.pink):setForeground(colors.black)
    local testBtn     = controlPanel:addButton():setPosition(27, yPos + 1):setSize(12, 1)
                                    :setText("Run Tests"):setBackground(colors.cyan):setForeground(colors.black)

    startAllBtn:onClick(function()
        for k in pairs(serverConfigs) do
            local ok, msg = startServer(k)
            addLogMessage("Start " .. serverConfigs[k].name .. ": " .. msg, ok and colors.green or colors.red)
        end
        updateServerStatus()
    end)
    stopAllBtn:onClick(function()
        for k in pairs(serverConfigs) do
            local ok, msg = stopServer(k)
            addLogMessage("Stop " .. serverConfigs[k].name .. ": " .. msg, ok and colors.green or colors.red)
        end
        updateServerStatus()
    end)
    testBtn:onClick(function()
        addLogMessage("Running server tests...", colors.yellow)
        for _, cfg in pairs(serverConfigs) do
            if cfg.status == "running" and cfg.instance and cfg.instance.test then
                cfg.instance.test()
                addLogMessage(cfg.name .. " test completed", colors.green)
            end
        end
    end)

    -- Log panel
    local logPanel = main:addFrame():setPosition(2, 16):setSize(w-2, h-16):setBackground(colors.black)
    logPanel:addLabel():setPosition(1, 1):setText("Server Logs"):setForeground(colors.white)
    logList = logPanel:addList():setPosition(1, 2):setSize(w-2, h-18)
                      :setBackground(colors.black):setForeground(colors.white)

    -- Exit
    local exitBtn = main:addButton():setPosition(w-8, h):setSize(8, 1)
                        :setText("Exit"):setBackground(colors.red):setForeground(colors.white)
    exitBtn:onClick(function() launcher.running = false end)

    addLogMessage("Server Launcher initialized", colors.lime)
    addLogMessage("Computer ID: " .. os.getComputerID(), colors.cyan)
end

-- Main execution
local function main_loop()
    createMainUI()

    while launcher.running do
        local ev = { os.pullEventRaw() }
        basalt.update(table.unpack(ev))
        if ev[1] == "terminate" then
            for k in pairs(serverConfigs) do
                if serverConfigs[k].status == "running" then stopServer(k) end
            end
            launcher.running = false
        end
    end

    term.clear()
    term.setCursorPos(1, 1)
    print("Server Launcher exited.")
end

-- Export + optional auto-run
launcher.startServer   = startServer
launcher.stopServer    = stopServer
launcher.getServerStats= getServerStats
launcher.serverConfigs = serverConfigs

if not _G.server_launcher then
    _G.server_launcher = launcher
    main_loop()
end

return launcher
