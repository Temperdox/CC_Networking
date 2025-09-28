-- user_startup.lua
-- User-customizable startup script with logging
-- This file is executed after the main system startup

-- Logging utility
local function writeLog(message, level)
    level = level or "INFO"
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local log_entry = string.format("[%s] [%s] %s", timestamp, level, message)

    -- Print to console
    print(log_entry)

    -- Ensure logs directory exists
    if not fs.exists("logs") then
        fs.makeDir("logs")
    end

    -- Write to user startup log
    local log_file = fs.open("logs/user_startup.log", "a")
    if log_file then
        log_file.writeLine(log_entry)
        log_file.close()
    end
end

local function logError(message, error_details)
    writeLog(message .. " - " .. tostring(error_details), "ERROR")
end

local function logSuccess(message)
    writeLog(message, "SUCCESS")
end

local function logInfo(message)
    writeLog(message, "INFO")
end

local function logWarning(message)
    writeLog(message, "WARNING")
end

-- Safe execution wrapper
local function safeExecute(func, description)
    logInfo("Executing: " .. description)
    local success, result = pcall(func)

    if success then
        logSuccess(description .. " completed successfully")
        return true, result
    else
        logError(description .. " failed", result)
        return false, result
    end
end

-- Example user customizations with logging
local function customizePrompt()
    logInfo("Customizing shell prompt...")

    -- Example: Change shell prompt
    if shell and shell.setPath then
        local current_path = shell.path()
        shell.setPath(current_path .. ":/usr/local/bin")
        logInfo("Added /usr/local/bin to shell path")
    end

    logSuccess("Prompt customization completed")
end

local function loadUserPrograms()
    logInfo("Loading user programs...")

    local user_programs = {
        "/programs/custom_tool.lua",
        "/programs/network_monitor.lua",
        "/programs/auto_backup.lua"
    }

    local loaded_count = 0
    for _, program in ipairs(user_programs) do
        if fs.exists(program) then
            safeExecute(function()
                dofile(program)
            end, "Load program: " .. program)
            loaded_count = loaded_count + 1
        else
            logInfo("Optional program not found: " .. program)
        end
    end

    logSuccess("User programs loaded - " .. loaded_count .. " programs")
end

local function setupUserServices()
    logInfo("Setting up user services...")

    -- Example: Start a custom service
    safeExecute(function()
        -- Custom service startup code here
        logInfo("Custom service initialized")
    end, "Custom service startup")

    -- Example: Set up automatic tasks
    safeExecute(function()
        -- Schedule periodic tasks
        logInfo("Periodic tasks scheduled")
    end, "Task scheduler setup")

    logSuccess("User services setup completed")
end

local function displayUserWelcome()
    logInfo("Displaying user welcome message...")

    print()
    print("========== Welcome ==========")
    print("Computer: " .. (os.getComputerLabel() or ("Computer " .. os.getComputerID())))
    print("User startup completed successfully")
    print("Time: " .. os.date("%Y-%m-%d %H:%M:%S"))
    print("============================")
    print()

    logInfo("Welcome message displayed")
end

-- Main user startup function
local function main()
    local startup_begin = os.epoch("utc")

    logInfo("User startup initiated")
    logInfo("User: " .. (os.getComputerLabel() or "Unknown"))
    logInfo("Computer ID: " .. os.getComputerID())

    local overall_success = true

    -- Customize shell and environment
    local success = safeExecute(customizePrompt, "Shell customization")
    if not success then overall_success = false end

    -- Load user programs
    success = safeExecute(loadUserPrograms, "User program loading")
    if not success then overall_success = false end

    -- Setup user services
    success = safeExecute(setupUserServices, "User service setup")
    if not success then overall_success = false end

    -- Display welcome message
    safeExecute(displayUserWelcome, "Welcome message display")

    local startup_duration = os.epoch("utc") - startup_begin

    if overall_success then
        logSuccess("User startup completed successfully in " .. startup_duration .. "ms")
    else
        logWarning("User startup completed with some issues in " .. startup_duration .. "ms")
    end

    return overall_success
end

-- Example of how users can add their own custom functions
local function myCustomFunction()
    logInfo("Running custom user function...")

    -- User can add their custom startup code here
    -- Examples:
    -- - Start custom programs
    -- - Configure network settings
    -- - Set up monitoring
    -- - Initialize hardware

    logSuccess("Custom function completed")
end

-- Run user startup with comprehensive error handling
logInfo("=== USER STARTUP BEGIN ===")

local startup_success, startup_error = pcall(main)

if not startup_success then
    -- Critical startup failure
    writeLog("CRITICAL: User startup failed completely: " .. tostring(startup_error), "CRITICAL")
    print("CRITICAL USER STARTUP FAILURE")
    print("Check logs/user_startup.log for details")
    print("Error: " .. tostring(startup_error))
else
    -- Run any additional custom functions
    pcall(myCustomFunction)
end

logInfo("=== USER STARTUP END ===")

-- Template for users to copy and modify:
--[[
To customize this file:

1. Add your custom functions before the main() function
2. Call your functions from within main() using safeExecute()
3. Use the logging functions to track what your code is doing:
   - logInfo() for informational messages
   - logSuccess() for successful operations
   - logWarning() for non-critical issues
   - logError() for serious problems

Example:
local function startMyProgram()
    logInfo("Starting my custom program...")
    shell.run("/programs/my_program.lua")
    logSuccess("My program started")
end

Then call it from main():
safeExecute(startMyProgram, "My custom program startup")
--]]