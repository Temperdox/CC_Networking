-- /tests/servers/http_server.lua
-- HTTP Test Server for ComputerCraft Network System
-- Returns Basalt XML for CC:Tweaked clients

local server = {}
server.version = "1.0.0"
server.running = false
server.stats = { requests = 0, errors = 0 }
server.start_time = os.epoch("utc")

-- Server configuration
local config = {
    port = 8080,
    host = "0.0.0.0",
    max_connections = 10,
    timeout = 30,
    log_requests = true
}

-- Simple logging
local function log(level, message, ...)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local formatted = string.format("[%s] HTTP Server %s: %s", timestamp, level, string.format(message, ...))
    print(formatted)

    if not fs.exists("/var/log") then fs.makeDir("/var/log") end
    local logFile = fs.open("/var/log/http_server.log", "a")
    if logFile then
        logFile.writeLine(formatted)
        logFile.close()
    end
end

-- HTTP Status Codes
local statusCodes = {
    [200] = "OK", [201] = "Created", [400] = "Bad Request",
    [404] = "Not Found", [500] = "Internal Server Error"
}

-- Create HTTP response
local function createResponse(code, headers, body)
    headers = headers or {}
    body = body or ""

    if not headers["content-type"] then headers["content-type"] = "application/xml" end
    if not headers["server"] then headers["server"] = "CC-HTTP/" .. server.version end

    return {
        code = code,
        headers = headers,
        body = body
    }
end

-- Create Basalt XML UI
local function createBasaltXML(title, elements)
    local xml = string.format([[
<basalt>
    <frame name="main" x="1" y="1" width="51" height="19" background="blue">
        <label name="title" x="2" y="2" text="%s" foreground="white"/>
        %s
    </frame>
</basalt>]], title, table.concat(elements, "\n        "))
    return xml
end

-- Route handlers returning Basalt XML
local routes = {}

routes["/"] = function(req)
    local elements = {
        '<label name="version" x="2" y="4" text="Server Version: ' .. server.version .. '" foreground="lightGray"/>',
        '<label name="computer" x="2" y="5" text="Computer ID: ' .. os.getComputerID() .. '" foreground="lightGray"/>',
        '<label name="uptime" x="2" y="6" text="Uptime: ' .. math.floor((os.epoch("utc") - server.start_time) / 1000) .. 's" foreground="lightGray"/>',
        '<label name="endpoints_title" x="2" y="8" text="Available Endpoints:" foreground="yellow"/>',
        '<label name="ep1" x="3" y="9" text="GET /api/status - Server status" foreground="white"/>',
        '<label name="ep2" x="3" y="10" text="GET /api/time - Time info" foreground="white"/>',
        '<label name="ep3" x="3" y="11" text="GET /api/computer - Computer info" foreground="white"/>',
        '<label name="ep4" x="3" y="12" text="POST /api/test - Test endpoint" foreground="white"/>',
        '<button name="status_btn" x="2" y="14" width="12" height="1" text="Get Status" background="green" foreground="white"/>',
        '<button name="time_btn" x="15" y="14" width="10" height="1" text="Get Time" background="orange" foreground="white"/>',
        '<input name="test_input" x="2" y="16" width="20" height="1" placeholder="Enter test data"/>',
        '<button name="test_btn" x="23" y="16" width="8" height="1" text="Test POST" background="red" foreground="white"/>'
    }

    local xml = createBasaltXML("CC HTTP Test Server", elements)
    return createResponse(200, {["content-type"] = "application/xml"}, xml)
end

routes["/api/status"] = function(req)
    -- Return both JSON for API clients and XML for Basalt clients
    if req.headers and req.headers["accept"] == "application/json" then
        local status = {
            server = "CC-HTTP/" .. server.version,
            uptime = os.epoch("utc") - server.start_time,
            requests_served = server.stats.requests,
            errors = server.stats.errors,
            computer_id = os.getComputerID(),
            memory_usage = math.floor(collectgarbage("count")),
            timestamp = os.epoch("utc")
        }
        return createResponse(200, {["content-type"] = "application/json"}, textutils.serializeJSON(status))
    else
        -- Return Basalt XML
        local elements = {
            '<label name="server_info" x="2" y="4" text="Server: CC-HTTP/' .. server.version .. '" foreground="lime"/>',
            '<label name="uptime_info" x="2" y="5" text="Uptime: ' .. math.floor((os.epoch("utc") - server.start_time) / 1000) .. ' seconds" foreground="white"/>',
            '<label name="requests_info" x="2" y="6" text="Requests: ' .. server.stats.requests .. '" foreground="white"/>',
            '<label name="errors_info" x="2" y="7" text="Errors: ' .. server.stats.errors .. '" foreground="red"/>',
            '<label name="computer_info" x="2" y="8" text="Computer ID: ' .. os.getComputerID() .. '" foreground="cyan"/>',
            '<label name="memory_info" x="2" y="9" text="Memory: ' .. math.floor(collectgarbage("count")) .. ' KB" foreground="yellow"/>',
            '<label name="timestamp" x="2" y="10" text="Timestamp: ' .. os.epoch("utc") .. '" foreground="lightGray"/>',
            '<button name="refresh_btn" x="2" y="12" width="10" height="1" text="Refresh" background="blue" foreground="white"/>',
            '<button name="back_btn" x="13" y="12" width="8" height="1" text="Back" background="gray" foreground="white"/>'
        }

        local xml = createBasaltXML("Server Status", elements)
        return createResponse(200, {["content-type"] = "application/xml"}, xml)
    end
end

routes["/api/time"] = function(req)
    if req.headers and req.headers["accept"] == "application/json" then
        local timeInfo = {
            epoch_utc = os.epoch("utc"),
            epoch_local = os.epoch("local"),
            day = os.day(),
            time = os.time(),
            formatted = os.date("%Y-%m-%d %H:%M:%S")
        }
        return createResponse(200, {["content-type"] = "application/json"}, textutils.serializeJSON(timeInfo))
    else
        local elements = {
            '<label name="epoch_utc" x="2" y="4" text="Epoch UTC: ' .. os.epoch("utc") .. '" foreground="lime"/>',
            '<label name="epoch_local" x="2" y="5" text="Epoch Local: ' .. os.epoch("local") .. '" foreground="lime"/>',
            '<label name="day" x="2" y="6" text="Day: ' .. os.day() .. '" foreground="white"/>',
            '<label name="time" x="2" y="7" text="Time: ' .. string.format("%.2f", os.time()) .. '" foreground="white"/>',
            '<label name="formatted" x="2" y="8" text="Formatted: ' .. os.date("%Y-%m-%d %H:%M:%S") .. '" foreground="yellow"/>',
            '<button name="refresh_btn" x="2" y="10" width="10" height="1" text="Refresh" background="blue" foreground="white"/>',
            '<button name="back_btn" x="13" y="10" width="8" height="1" text="Back" background="gray" foreground="white"/>'
        }

        local xml = createBasaltXML("Time Information", elements)
        return createResponse(200, {["content-type"] = "application/xml"}, xml)
    end
end

routes["/api/computer"] = function(req)
    if req.headers and req.headers["accept"] == "application/json" then
        local info = {
            id = os.getComputerID(),
            label = os.getComputerLabel(),
            version = os.version(),
            uptime = os.clock()
        }
        return createResponse(200, {["content-type"] = "application/json"}, textutils.serializeJSON(info))
    else
        local elements = {
            '<label name="id" x="2" y="4" text="ID: ' .. os.getComputerID() .. '" foreground="cyan"/>',
            '<label name="label" x="2" y="5" text="Label: ' .. (os.getComputerLabel() or "None") .. '" foreground="cyan"/>',
            '<label name="version" x="2" y="6" text="Version: ' .. os.version() .. '" foreground="white"/>',
            '<label name="uptime" x="2" y="7" text="Uptime: ' .. string.format("%.2f", os.clock()) .. 's" foreground="white"/>',
            '<button name="back_btn" x="2" y="9" width="8" height="1" text="Back" background="gray" foreground="white"/>'
        }

        local xml = createBasaltXML("Computer Information", elements)
        return createResponse(200, {["content-type"] = "application/xml"}, xml)
    end
end

routes["/api/test"] = function(req)
    if req.method == "POST" then
        local result = {
            message = "POST request received successfully",
            data_received = req.body or "No data",
            processed_at = os.date("%Y-%m-%d %H:%M:%S"),
            request_method = req.method
        }

        if req.headers and req.headers["accept"] == "application/json" then
            return createResponse(200, {["content-type"] = "application/json"}, textutils.serializeJSON(result))
        else
            local elements = {
                '<label name="success" x="2" y="4" text="POST Request Successful!" foreground="lime"/>',
                '<label name="data" x="2" y="5" text="Data: ' .. (req.body or "None") .. '" foreground="white"/>',
                '<label name="time" x="2" y="6" text="Processed: ' .. os.date("%H:%M:%S") .. '" foreground="yellow"/>',
                '<button name="back_btn" x="2" y="8" width="8" height="1" text="Back" background="gray" foreground="white"/>'
            }

            local xml = createBasaltXML("Test Result", elements)
            return createResponse(200, {["content-type"] = "application/xml"}, xml)
        end
    else
        return createResponse(405, {}, "Method not allowed")
    end
end

-- Error handler
local function handleError(code, message)
    local elements = {
        '<label name="error_code" x="2" y="4" text="Error ' .. code .. '" foreground="red"/>',
        '<label name="error_msg" x="2" y="5" text="' .. message .. '" foreground="white"/>',
        '<button name="back_btn" x="2" y="7" width="8" height="1" text="Back" background="gray" foreground="white"/>'
    }

    local xml = createBasaltXML("Error", elements)
    return createResponse(code, {["content-type"] = "application/xml"}, xml)
end

-- Request handler
local function handleRequest(request)
    server.stats.requests = server.stats.requests + 1

    local path = request.path or "/"
    local handler = routes[path]

    if config.log_requests then
        log("INFO", "%s %s from %s", request.method or "GET", path, request.source or "unknown")
    end

    if handler then
        local ok, response = pcall(handler, request)
        if ok then
            return response
        else
            server.stats.errors = server.stats.errors + 1
            log("ERROR", "Handler error for %s: %s", path, response)
            return handleError(500, "Internal server error")
        end
    else
        return handleError(404, "Page not found: " .. path)
    end
end

-- Server management
function server.start()
    if server.running then
        print("HTTP server already running")
        return false
    end

    -- Register with netd if available
    if _G.network_state and _G.network_state.servers then
        _G.network_state.servers[config.port] = {
            handler = handleRequest,
            type = "http",
            started = os.epoch("utc")
        }
        log("INFO", "Registered HTTP server with netd on port %d", config.port)
    end

    server.running = true
    server.start_time = os.epoch("utc")
    log("INFO", "HTTP server started on port %d", config.port)

    return true
end

function server.stop()
    if not server.running then
        return false
    end

    -- Unregister from netd
    if _G.network_state and _G.network_state.servers then
        _G.network_state.servers[config.port] = nil
    end

    server.running = false
    log("INFO", "HTTP server stopped")

    return true
end

function server.getStats()
    return {
        running = server.running,
        port = config.port,
        requests = server.stats.requests,
        errors = server.stats.errors,
        uptime = server.running and (os.epoch("utc") - server.start_time) or 0
    }
end

-- Auto-start if run directly
if not _G.http_test_server then
    _G.http_test_server = server
    server.start()

    print("HTTP Test Server started. Press Ctrl+T to stop.")
    print("Available at: http://localhost:" .. config.port)
    print("Try: /api/status, /api/time, /api/computer")

    -- Keep running until terminated
    while server.running do
        local event = os.pullEvent()
        if event == "terminate" then
            server.stop()
            break
        end
    end
end

return server