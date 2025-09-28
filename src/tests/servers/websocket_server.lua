-- /tests/servers/websocket_server.lua
-- WebSocket Test Server for ComputerCraft Network System
-- Provides real-time communication testing with Basalt UI support

local server = {}
server.version = "1.0.0"
server.running = false
server.connections = {}
server.stats = { connections = 0, messages = 0, errors = 0 }
server.start_time = os.epoch("utc")

-- Server configuration
local config = {
    port = 8081,
    host = "0.0.0.0",
    max_connections = 20,
    heartbeat_interval = 30,
    log_messages = true
}

-- Simple logging
local function log(level, message, ...)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local formatted = string.format("[%s] WS Server %s: %s", timestamp, level, string.format(message, ...))
    print(formatted)

    if not fs.exists("/var/log") then fs.makeDir("/var/log") end
    local logFile = fs.open("/var/log/websocket_server.log", "a")
    if logFile then
        logFile.writeLine(formatted)
        logFile.close()
    end
end

-- Generate connection ID
local function generateConnectionId()
    return "ws_" .. os.getComputerID() .. "_" .. os.epoch("utc") .. "_" .. math.random(1000, 9999)
end

-- Broadcast message to all connections
local function broadcast(message, excludeId)
    local sent = 0
    for connId, conn in pairs(server.connections) do
        if connId ~= excludeId and conn.active then
            if rednet.isOpen() then
                local packet = {
                    type = "ws_data",
                    connectionId = connId,
                    data = message,
                    timestamp = os.epoch("utc")
                }
                rednet.send(conn.peer, packet, "websocket")
                sent = sent + 1
            end
        end
    end
    return sent
end

-- Create Basalt XML for WebSocket UI
local function createBasaltXML(title, elements)
    local xml = string.format([[
<basalt>
    <frame name="main" x="1" y="1" width="51" height="19" background="black">
        <label name="title" x="2" y="1" text="%s" foreground="white" background="blue"/>
        %s
    </frame>
</basalt>]], title, table.concat(elements, "\n        "))
    return xml
end

-- WebSocket handlers
local wsHandlers = {}

wsHandlers["connect"] = function(sender, message)
    local connId = generateConnectionId()

    server.connections[connId] = {
        id = connId,
        peer = sender,
        established = os.epoch("utc"),
        lastActivity = os.epoch("utc"),
        active = true,
        messages_sent = 0,
        messages_received = 0
    }

    server.stats.connections = server.stats.connections + 1

    -- Send acceptance
    local response = {
        type = "ws_accept",
        connectionId = connId,
        server_info = {
            version = server.version,
            computer_id = os.getComputerID(),
            timestamp = os.epoch("utc")
        }
    }

    if rednet.isOpen() then
        rednet.send(sender, response, "websocket")
    end

    -- Send welcome message with Basalt UI
    local elements = {
        '<label name="welcome" x="2" y="3" text="WebSocket Connected!" foreground="lime"/>',
        '<label name="conn_id" x="2" y="4" text="Connection: ' .. connId .. '" foreground="cyan"/>',
        '<label name="server_info" x="2" y="5" text="Server: CC-WS/' .. server.version .. '" foreground="white"/>',
        '<label name="active_conns" x="2" y="6" text="Active connections: ' .. #server.connections .. '" foreground="yellow"/>',
        '<textfield name="message_input" x="2" y="8" width="40" height="1" placeholder="Type message here"/>',
        '<button name="send_btn" x="2" y="10" width="12" height="1" text="Send Message" background="green"/>',
        '<button name="broadcast_btn" x="15" y="10" width="12" height="1" text="Broadcast" background="orange"/>',
        '<button name="ping_btn" x="28" y="10" width="8" height="1" text="Ping" background="blue"/>',
        '<label name="status" x="2" y="12" text="Status: Connected" foreground="lime"/>',
        '<label name="last_msg" x="2" y="13" text="Last message: Welcome!" foreground="white"/>',
        '<button name="disconnect_btn" x="2" y="15" width="12" height="1" text="Disconnect" background="red"/>'
    }

    local welcomeUI = createBasaltXML("WebSocket Client", elements)

    local welcomePacket = {
        type = "ws_data",
        connectionId = connId,
        data = welcomeUI,
        content_type = "application/xml",
        timestamp = os.epoch("utc")
    }

    if rednet.isOpen() then
        rednet.send(sender, welcomePacket, "websocket")
    end

    -- Announce new connection to other clients
    broadcast("New client connected: " .. connId, connId)

    log("INFO", "WebSocket connection established: %s from computer %d", connId, sender)
    return connId
end

wsHandlers["data"] = function(sender, message)
    local connId = message.connectionId
    local conn = server.connections[connId]

    if not conn or not conn.active then
        log("WARN", "Received data for inactive connection: %s", connId)
        return
    end

    conn.lastActivity = os.epoch("utc")
    conn.messages_received = conn.messages_received + 1
    server.stats.messages = server.stats.messages + 1

    local data = message.data or ""

    if config.log_messages then
        log("DEBUG", "WebSocket message from %s: %s", connId, string.sub(data, 1, 100))
    end

    -- Handle different message types
    if data:match("^/ping") then
        -- Ping command
        local response = {
            type = "ws_data",
            connectionId = connId,
            data = "Pong! Server time: " .. os.date("%H:%M:%S"),
            timestamp = os.epoch("utc")
        }
        rednet.send(sender, response, "websocket")

    elseif data:match("^/broadcast ") then
        -- Broadcast command
        local broadcastMsg = data:match("^/broadcast (.+)")
        local count = broadcast("[Broadcast from " .. connId .. "] " .. broadcastMsg, connId)

        local response = {
            type = "ws_data",
            connectionId = connId,
            data = "Broadcast sent to " .. count .. " clients",
            timestamp = os.epoch("utc")
        }
        rednet.send(sender, response, "websocket")

    elseif data:match("^/status") then
        -- Status command - return Basalt XML
        local elements = {
            '<label name="server_status" x="2" y="3" text="WebSocket Server Status" foreground="yellow"/>',
            '<label name="uptime" x="2" y="4" text="Uptime: ' .. math.floor((os.epoch("utc") - server.start_time) / 1000) .. 's" foreground="white"/>',
            '<label name="connections" x="2" y="5" text="Active connections: ' .. #server.connections .. '" foreground="cyan"/>',
            '<label name="total_connections" x="2" y="6" text="Total connections: ' .. server.stats.connections .. '" foreground="white"/>',
            '<label name="messages" x="2" y="7" text="Messages processed: ' .. server.stats.messages .. '" foreground="white"/>',
            '<label name="your_conn" x="2" y="8" text="Your connection: ' .. connId .. '" foreground="lime"/>',
            '<label name="your_messages" x="2" y="9" text="Your messages: " foreground="white"/>',
            '<label name="sent_count" x="2" y="10" text="  Sent: ' .. conn.messages_sent .. '" foreground="white"/>',
            '<label name="received_count" x="2" y="11" text="  Received: ' .. conn.messages_received .. '" foreground="white"/>',
            '<button name="refresh_btn" x="2" y="13" width="10" height="1" text="Refresh" background="blue"/>'
        }

        local statusXML = createBasaltXML("Server Status", elements)

        local response = {
            type = "ws_data",
            connectionId = connId,
            data = statusXML,
            content_type = "application/xml",
            timestamp = os.epoch("utc")
        }
        rednet.send(sender, response, "websocket")

    elseif data:match("^/help") then
        -- Help command
        local elements = {
            '<label name="help_title" x="2" y="3" text="WebSocket Server Commands" foreground="yellow"/>',
            '<label name="cmd1" x="2" y="4" text="/ping - Test connection" foreground="white"/>',
            '<label name="cmd2" x="2" y="5" text="/status - Server status" foreground="white"/>',
            '<label name="cmd3" x="2" y="6" text="/broadcast <msg> - Send to all" foreground="white"/>',
            '<label name="cmd4" x="2" y="7" text="/users - List active users" foreground="white"/>',
            '<label name="cmd5" x="2" y="8" text="/time - Current server time" foreground="white"/>',
            '<label name="cmd6" x="2" y="9" text="/help - This help text" foreground="white"/>',
            '<label name="note" x="2" y="11" text="Or just type normal messages!" foreground="lightGray"/>'
        }

        local helpXML = createBasaltXML("Help", elements)

        local response = {
            type = "ws_data",
            connectionId = connId,
            data = helpXML,
            content_type = "application/xml",
            timestamp = os.epoch("utc")
        }
        rednet.send(sender, response, "websocket")

    elseif data:match("^/users") then
        -- List users
        local userList = {}
        for id, conn in pairs(server.connections) do
            if conn.active then
                table.insert(userList, id .. " (msgs: " .. conn.messages_received .. ")")
            end
        end

        local elements = {'<label name="users_title" x="2" y="3" text="Active Connections" foreground="yellow"/>'}
        for i, user in ipairs(userList) do
            table.insert(elements, '<label name="user' .. i .. '" x="2" y="' .. (3 + i) .. '" text="' .. user .. '" foreground="white"/>')
        end

        local usersXML = createBasaltXML("Active Users", elements)

        local response = {
            type = "ws_data",
            connectionId = connId,
            data = usersXML,
            content_type = "application/xml",
            timestamp = os.epoch("utc")
        }
        rednet.send(sender, response, "websocket")

    elseif data:match("^/time") then
        local response = {
            type = "ws_data",
            connectionId = connId,
            data = "Server time: " .. os.date("%Y-%m-%d %H:%M:%S") .. " (UTC: " .. os.epoch("utc") .. ")",
            timestamp = os.epoch("utc")
        }
        rednet.send(sender, response, "websocket")

    else
        -- Regular message - echo back and broadcast to others
        local echo = {
            type = "ws_data",
            connectionId = connId,
            data = "[Echo] " .. data,
            timestamp = os.epoch("utc")
        }
        rednet.send(sender, echo, "websocket")

        -- Broadcast to other clients
        broadcast("[" .. connId .. "] " .. data, connId)
    end

    conn.messages_sent = conn.messages_sent + 1
end

wsHandlers["close"] = function(sender, message)
    local connId = message.connectionId
    local conn = server.connections[connId]

    if conn then
        conn.active = false
        server.connections[connId] = nil

        -- Notify other clients
        broadcast("Client disconnected: " .. connId, connId)

        log("INFO", "WebSocket connection closed: %s", connId)
    end
end

-- Main WebSocket handler
local function handleWebSocket(sender, message)
    if not message or not message.type then
        return false
    end

    local handler = wsHandlers[message.type:gsub("^ws_", "")]
    if handler then
        local ok, result = pcall(handler, sender, message)
        if not ok then
            server.stats.errors = server.stats.errors + 1
            log("ERROR", "WebSocket handler error: %s", result)
        end
        return ok
    end

    return false
end

-- Server management
function server.start()
    if server.running then
        print("WebSocket server already running")
        return false
    end

    -- Register with netd if available
    if _G.network_state and _G.network_state.servers then
        _G.network_state.servers[config.port] = {
            handler = handleWebSocket,
            ws_handler = handleWebSocket,
            type = "websocket",
            started = os.epoch("utc")
        }
        log("INFO", "Registered WebSocket server with netd on port %d", config.port)
    end

    server.running = true
    server.start_time = os.epoch("utc")
    log("INFO", "WebSocket server started on port %d", config.port)

    return true
end

function server.stop()
    if not server.running then
        return false
    end

    -- Close all connections
    for connId, conn in pairs(server.connections) do
        if conn.active then
            local closeMsg = {
                type = "ws_close",
                connectionId = connId,
                reason = "Server shutting down"
            }
            rednet.send(conn.peer, closeMsg, "websocket")
        end
    end

    server.connections = {}

    -- Unregister from netd
    if _G.network_state and _G.network_state.servers then
        _G.network_state.servers[config.port] = nil
    end

    server.running = false
    log("INFO", "WebSocket server stopped")

    return true
end

function server.getStats()
    local activeConnections = 0
    for _, conn in pairs(server.connections) do
        if conn.active then
            activeConnections = activeConnections + 1
        end
    end

    return {
        running = server.running,
        port = config.port,
        active_connections = activeConnections,
        total_connections = server.stats.connections,
        messages = server.stats.messages,
        errors = server.stats.errors,
        uptime = server.running and (os.epoch("utc") - server.start_time) or 0
    }
end

-- Cleanup inactive connections
local function cleanupConnections()
    local timeout = 300000 -- 5 minutes
    local now = os.epoch("utc")
    local cleaned = 0

    for connId, conn in pairs(server.connections) do
        if (now - conn.lastActivity) > timeout then
            conn.active = false
            server.connections[connId] = nil
            cleaned = cleaned + 1
            log("DEBUG", "Cleaned up inactive connection: %s", connId)
        end
    end

    return cleaned
end

-- Auto-start if run directly
if not _G.websocket_test_server then
    _G.websocket_test_server = server
    server.start()

    print("WebSocket Test Server started. Press Ctrl+T to stop.")
    print("Listening on port " .. config.port)
    print("Commands: /ping, /status, /broadcast <msg>, /users, /time, /help")

    local cleanupTimer = os.startTimer(60) -- Cleanup every minute

    -- Keep running until terminated
    while server.running do
        local event, p1 = os.pullEvent()

        if event == "terminate" then
            server.stop()
            break
        elseif event == "timer" and p1 == cleanupTimer then
            local cleaned = cleanupConnections()
            if cleaned > 0 then
                log("INFO", "Cleaned up %d inactive connections", cleaned)
            end
            cleanupTimer = os.startTimer(60)
        end
    end
end

return server