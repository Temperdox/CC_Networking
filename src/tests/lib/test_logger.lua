-- /tests/lib/test_logger.lua
-- Comprehensive logging framework for network tests
-- Provides structured logging for all test activities

local TestLogger = {}
TestLogger.__index = TestLogger

-- Create new logger instance
function TestLogger:new(name, options)
    options = options or {}
    local instance = {
        name = name,
        log_dir = options.log_dir or "/var/log/tests",
        console = options.console ~= false,
        buffer_size = options.buffer_size or 20,
        buffer = {},
        start_time = os.epoch("utc"),
        test_results = {},
        current_test = nil
    }

    setmetatable(instance, TestLogger)
    instance:ensureLogDir()
    instance:writeHeader()
    return instance
end

-- Ensure log directory exists
function TestLogger:ensureLogDir()
    if not fs.exists(self.log_dir) then
        fs.makeDir(self.log_dir)
    end
end

-- Get log file path
function TestLogger:getLogPath()
    local date = os.date("%Y%m%d")
    local filename = string.format("%s_%s.log", self.name, date)
    return fs.combine(self.log_dir, filename)
end

-- Write log header
function TestLogger:writeHeader()
    self:log("========================================", "HEADER")
    self:log(string.format("Test: %s", self.name), "HEADER")
    self:log(string.format("Started: %s", os.date("%Y-%m-%d %H:%M:%S")), "HEADER")
    self:log(string.format("Computer ID: %d", os.getComputerID()), "HEADER")
    self:log("========================================", "HEADER")
end

-- Flush buffer to file
function TestLogger:flush()
    if #self.buffer == 0 then return end

    local logFile = fs.open(self:getLogPath(), "a")
    if logFile then
        for _, entry in ipairs(self.buffer) do
            logFile.writeLine(entry)
        end
        logFile.close()
    end
    self.buffer = {}
end

-- Log message
function TestLogger:log(message, level)
    level = level or "INFO"
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local elapsed = math.floor((os.epoch("utc") - self.start_time) / 1000)

    local entry = string.format("[%s] [%s] [+%ds] %s",
            timestamp, level, elapsed, message)

    -- Add to buffer
    table.insert(self.buffer, entry)

    -- Console output
    if self.console then
        local colors = {
            ERROR = colors.red,
            WARN = colors.yellow,
            SUCCESS = colors.green,
            INFO = colors.white,
            DEBUG = colors.gray,
            HEADER = colors.cyan
        }

        if term.isColor and term.isColor() and colors[level] then
            local oldColor = term.getTextColor()
            term.setTextColor(colors[level])
            print(string.format("[%s] %s", level, message))
            term.setTextColor(oldColor)
        else
            print(string.format("[%s] %s", level, message))
        end
    end

    -- Auto-flush
    if #self.buffer >= self.buffer_size then
        self:flush()
    end
end

-- Convenience methods
function TestLogger:info(msg)    self:log(msg, "INFO") end
function TestLogger:debug(msg)   self:log(msg, "DEBUG") end
function TestLogger:warn(msg)    self:log(msg, "WARN") end
function TestLogger:error(msg)   self:log(msg, "ERROR") end
function TestLogger:success(msg) self:log(msg, "SUCCESS") end

-- Start a test
function TestLogger:startTest(name)
    self.current_test = {
        name = name,
        start_time = os.epoch("utc"),
        steps = {},
        errors = {},
        success = true
    }
    self:log(string.format("Test Started: %s", name), "INFO")
end

-- Log test step
function TestLogger:step(description, success)
    if not self.current_test then return end

    local step = {
        description = description,
        success = success ~= false,
        time = os.epoch("utc")
    }

    table.insert(self.current_test.steps, step)

    if step.success then
        self:log(string.format("  ✓ %s", description), "SUCCESS")
    else
        self:log(string.format("  ✗ %s", description), "ERROR")
        self.current_test.success = false
    end
end

-- End current test
function TestLogger:endTest(success)
    if not self.current_test then return end

    self.current_test.end_time = os.epoch("utc")
    self.current_test.duration = self.current_test.end_time - self.current_test.start_time

    if success ~= nil then
        self.current_test.success = success
    end

    local status = self.current_test.success and "PASSED" or "FAILED"
    self:log(string.format("Test %s: %s (%.2fs)",
            status, self.current_test.name, self.current_test.duration / 1000),
            self.current_test.success and "SUCCESS" or "ERROR")

    table.insert(self.test_results, self.current_test)
    self.current_test = nil
end

-- Write summary
function TestLogger:writeSummary()
    self:log("========================================", "HEADER")
    self:log("Test Summary", "HEADER")
    self:log("========================================", "HEADER")

    local total = #self.test_results
    local passed = 0
    local failed = 0
    local total_duration = 0

    for _, test in ipairs(self.test_results) do
        if test.success then
            passed = passed + 1
        else
            failed = failed + 1
        end
        total_duration = total_duration + test.duration
    end

    self:log(string.format("Total Tests: %d", total), "INFO")
    self:log(string.format("Passed: %d", passed), "SUCCESS")
    self:log(string.format("Failed: %d", failed), failed > 0 and "ERROR" or "INFO")
    self:log(string.format("Total Duration: %.2fs", total_duration / 1000), "INFO")

    if failed > 0 then
        self:log("Failed Tests:", "ERROR")
        for _, test in ipairs(self.test_results) do
            if not test.success then
                self:log(string.format("  - %s", test.name), "ERROR")
            end
        end
    end

    self:log("========================================", "HEADER")
    self:flush()
end

-- Export results as JSON
function TestLogger:exportResults()
    local results = {
        name = self.name,
        computer_id = os.getComputerID(),
        start_time = self.start_time,
        tests = self.test_results
    }

    local jsonPath = fs.combine(self.log_dir,
            string.format("%s_%s_results.json", self.name, os.date("%Y%m%d_%H%M%S")))

    local file = fs.open(jsonPath, "w")
    if file then
        file.write(textutils.serializeJSON(results))
        file.close()
        self:log("Results exported to: " .. jsonPath, "SUCCESS")
    end

    return results
end

-- Clean old logs
function TestLogger:cleanOldLogs(daysToKeep)
    daysToKeep = daysToKeep or 7
    local cutoff = os.epoch("utc") - (daysToKeep * 24 * 60 * 60 * 1000)

    for _, file in ipairs(fs.list(self.log_dir)) do
        local path = fs.combine(self.log_dir, file)
        if not fs.isDir(path) then
            -- Try to parse date from filename
            local year, month, day = file:match("(%d%d%d%d)(%d%d)(%d%d)")
            if year then
                -- Simple date comparison (not perfect but good enough)
                local fileTime = os.time({
                    year = tonumber(year),
                    month = tonumber(month),
                    day = tonumber(day),
                    hour = 0, min = 0, sec = 0
                }) * 1000

                if fileTime < cutoff then
                    fs.delete(path)
                    self:log("Deleted old log: " .. file, "DEBUG")
                end
            end
        end
    end
end

return TestLogger

-----------------------------------------------------------
-- Example test file using the logger
-----------------------------------------------------------
-- /tests/test_http.lua
-- HTTP Protocol Test with Comprehensive Logging

local TestLogger = dofile("/tests/lib/test_logger.lua")
local logger = TestLogger:new("test_http")

local function runHTTPTests()
    logger:info("Initializing HTTP protocol tests")

    -- Load HTTP protocol
    logger:startTest("Load HTTP Protocol")
    local http_protocol = nil
    local ok, err = pcall(function()
        http_protocol = dofile("/protocols/http_client.lua")
    end)

    if ok and http_protocol then
        logger:step("HTTP protocol loaded successfully", true)
    else
        logger:step("Failed to load HTTP protocol: " .. tostring(err), false)
        logger:endTest(false)
        return false
    end
    logger:endTest(true)

    -- Test local HTTP request
    logger:startTest("Local HTTP Request")

    local response = http.get("http://127.0.0.1/test")
    if response then
        local code = response.getResponseCode()
        local body = response.readAll()
        response.close()

        logger:step(string.format("Request completed (code: %d)", code), true)
        logger:step("Response body received: " .. #body .. " bytes", true)

        if code == 200 then
            logger:step("Status code is 200 OK", true)
        else
            logger:step("Unexpected status code: " .. code, false)
        end
    else
        logger:step("HTTP request failed", false)
    end

    logger:endTest(response ~= nil)

    -- Test remote HTTP via rednet
    logger:startTest("Remote HTTP via Rednet")

    local modem = peripheral.find("modem")
    if not modem then
        logger:step("No modem found - skipping remote test", false)
        logger:endTest(false)
    else
        local side = peripheral.getName(modem)
        if not rednet.isOpen(side) then
            rednet.open(side)
            logger:step("Opened modem on side: " .. side, true)
        end

        -- Look for HTTP servers
        local servers = {rednet.lookup("http_server")}
        if #servers > 0 then
            logger:step(string.format("Found %d HTTP servers", #servers), true)

            -- Test first server
            local serverId = servers[1]
            local request = {
                type = "http_request",
                method = "GET",
                path = "/test",
                headers = {},
                id = math.random(100000, 999999)
            }

            rednet.send(serverId, request, "ccnet_http")
            logger:step(string.format("Sent request to server %d", serverId), true)

            local timeout = os.startTimer(5)
            local received = false

            while not received do
                local event, p1, p2, p3 = os.pullEvent()
                if event == "rednet_message" then
                    local sender, message, protocol = p1, p2, p3
                    if sender == serverId and message.id == request.id then
                        logger:step(string.format("Received response (code: %d)",
                                message.code or 0), true)
                        received = true
                    end
                elseif event == "timer" and p1 == timeout then
                    logger:step("Request timeout", false)
                    break
                end
            end

            logger:endTest(received)
        else
            logger:step("No HTTP servers found on network", false)
            logger:endTest(false)
        end
    end

    -- Test error handling
    logger:startTest("Error Handling")

    local ok, err = pcall(function()
        http.get("http://invalid.host.test/")
    end)

    if not ok then
        logger:step("Invalid host properly failed", true)
    else
        logger:step("Invalid host did not fail as expected", false)
    end

    logger:endTest(not ok)

    return true
end

-- Main execution
logger:info("HTTP Protocol Test Suite")
logger:info("Version: 1.0.0")

local success = runHTTPTests()

logger:writeSummary()
logger:exportResults()

if success then
    logger:success("All HTTP tests completed")
else
    logger:error("HTTP tests failed")
end

logger:flush()
print("\nTest logs saved to: " .. logger:getLogPath())