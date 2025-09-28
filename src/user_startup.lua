-- /user_startup.lua
-- User custom startup script - runs after main startup.lua
-- Add your custom initialization code here

-- Example user startup configuration
local USER_CONFIG = {
    -- Auto-connect to network
    auto_dhcp = true,

    -- Auto-connect to WiFi
    auto_wifi = false,
    wifi_ssid = nil,
    wifi_password = nil,

    -- Start services
    start_services = {
        web_server = false,
        file_server = false,
        chat_server = false
    },

    -- Custom aliases
    aliases = {
        ll = "ls -l",
        net = "network_demo.lua",
        wifi = "wifi_client.lua"
    }
}

-- Helper functions
local function log(message)
    print("[User Startup] " .. message)
end

local function fileExists(path)
    return fs.exists(path)
end

-- Auto DHCP configuration
local function autoDHCP()
    if USER_CONFIG.auto_dhcp and fileExists("/dhcp_client.lua") then
        log("Running automatic DHCP configuration...")

        -- Check if we already have an IP
        if fileExists("/etc/network.cfg") then
            local file = fs.open("/etc/network.cfg", "r")
            local content = file.readAll()
            file.close()

            local cfg = loadstring(content)
            if cfg then
                local config = cfg()
                if config.ip and config.ip ~= "" then
                    log("Already configured with IP: " .. config.ip)
                    return
                end
            end
        end

        -- Run DHCP client
        shell.run("/dhcp_client.lua")
    end
end

-- Auto WiFi connection
local function autoWiFi()
    if USER_CONFIG.auto_wifi and USER_CONFIG.wifi_ssid then
        log("Auto-connecting to WiFi: " .. USER_CONFIG.wifi_ssid)

        -- Check for wireless modem
        local hasWireless = false
        local sides = {"top", "bottom", "left", "right", "front", "back"}

        for _, side in ipairs(sides) do
            if peripheral.isPresent(side) and peripheral.getType(side) == "modem" then
                local modem = peripheral.wrap(side)
                if modem.isWireless and modem.isWireless() then
                    hasWireless = true
                    break
                end
            end
        end

        if hasWireless and fileExists("/wifi_client.lua") then
            -- Load WiFi client
            local WiFiClient = dofile("/wifi_client.lua")
            if WiFiClient then
                local client = WiFiClient:new()
                if client:findWirelessInterface() then
                    local success, err = client:connect(
                            USER_CONFIG.wifi_ssid,
                            USER_CONFIG.wifi_password
                    )

                    if success then
                        log("Successfully connected to WiFi")
                    else
                        log("WiFi connection failed: " .. (err or "unknown error"))
                    end
                end
            end
        else
            log("No wireless modem found for WiFi connection")
        end
    end
end

-- Start custom services
local function startServices()
    for service, enabled in pairs(USER_CONFIG.start_services) do
        if enabled then
            local service_path = "/services/" .. service .. ".lua"
            if fileExists(service_path) then
                log("Starting service: " .. service)
                shell.run("bg", service_path)
            else
                log("Service not found: " .. service)
            end
        end
    end
end

-- Set up aliases
local function setupAliases()
    for alias, command in pairs(USER_CONFIG.aliases) do
        shell.setAlias(alias, command)
        log("Added alias: " .. alias .. " -> " .. command)
    end
end

-- Custom initialization
local function customInit()
    -- Add your custom initialization code here

    -- Example: Set computer label if not set
    if not os.getComputerLabel() then
        local id = os.getComputerID()
        os.setComputerLabel("CC-" .. id)
        log("Set computer label to: CC-" .. id)
    end

    -- Example: Create work directories
    local dirs = {"/home", "/projects", "/downloads"}
    for _, dir in ipairs(dirs) do
        if not fs.exists(dir) then
            fs.makeDir(dir)
            log("Created directory: " .. dir)
        end
    end

    -- Example: Show network info if available
    if fileExists("/lib/network.lua") then
        local network = dofile("/lib/network.lua")
        if network and network.getInfo then
            local info = network.getInfo()
            if info then
                print()
                print("=== Network Information ===")
                print("Hostname: " .. (info.hostname or "unknown"))
                print("IP: " .. (info.ip or "not configured"))
                print("MAC: " .. (info.mac or "unknown"))
                print()
            end
        end
    end
end

-- Main execution
local function main()
    log("Starting user initialization...")

    -- Run initialization steps
    setupAliases()
    autoDHCP()
    autoWiFi()
    startServices()
    customInit()

    log("User initialization complete")

    -- Optional: Show a custom message
    print()
    print("=====================================")
    print(" Welcome to ComputerCraft Network")
    print(" Type 'help' for available commands")
    print("=====================================")
    print()
end

-- Run main function
main()