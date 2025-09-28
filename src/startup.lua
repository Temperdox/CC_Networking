-- startup.lua
-- ComputerCraft startup file - runs automatically when computer boots

-- Startup configuration
local STARTUP_CONFIG = {
    enableNetd = true,           -- Enable network daemon
    enableLogger = false,        -- Enable system logger
    netdBackground = true,       -- Run netd in background
    showNetInfo = true,         -- Show network info on startup
    startupDelay = 0.5,         -- Delay before starting services
}

-- Print startup banner
local function printBanner()
    term.clear()
    term.setCursorPos(1, 1)
    print("=====================================")
    print(" ComputerCraft Network System v1.0")
    print("=====================================")
    print()
end

-- Check if file exists
local function fileExists(path)
    return fs.exists(path)
end

-- Create required directories
local function createDirectories()
    local dirs = {
        "/etc",
        "/bin",
        "/lib",
        "/var",
        "/var/log",
        "/var/run",
        "/var/cache",
        "/logs",
        "/protocols",
        "/util",
        "/config"
    }

    for _, dir in ipairs(dirs) do
        if not fs.exists(dir) then
            fs.makeDir(dir)
            print("Created directory: " .. dir)
        end
    end
end

-- Generate network configuration
local function generateNetworkConfig(computerId, computerLabel)
    -- Generate MAC address based on computer ID
    local mac = string.format("CC:AF:%02X:%02X:%02X:%02X",
            bit.band(bit.brshift(computerId, 24), 0xFF),
            bit.band(bit.brshift(computerId, 16), 0xFF),
            bit.band(bit.brshift(computerId, 8), 0xFF),
            bit.band(computerId, 0xFF))

    -- Generate IP address (10.0.X.X subnet)
    local ip = string.format("10.0.%d.%d",
            math.floor(computerId / 254) % 256,
            (computerId % 254) + 1)

    -- Generate hostname
    local hostname = (computerLabel ~= "" and
            string.format("%s-%d", computerLabel:lower():gsub("[^%w%-]", ""), computerId) or
            string.format("cc-%d", computerId))

    return {
        id = computerId,
        label = computerLabel,
        modem_side = "auto",
        proto = "ccnet",
        discovery_proto = "ccnet_discovery",
        dns_proto = "ccnet_dns",
        arp_proto = "ccnet_arp",
        http_proto = "ccnet_http",
        ws_proto = "ccnet_ws",
        mac = mac,
        ipv4 = ip,
        ipv6 = nil,
        hostname = hostname,
        domain = "local",
        fqdn = hostname .. ".local",
        subnet_mask = "255.255.0.0",
        gateway = "10.0.0.1",
        dns = {
            primary = "10.0.0.1",
            secondary = "8.8.8.8"
        },
        services = {
            dns = { enabled = true, port = 53 },
            http = { enabled = true, port = 80 },
            https = { enabled = false, port = 443 },
            websocket = { enabled = true, port = 8080 },
            ssh = { enabled = false, port = 22 },
            ftp = { enabled = false, port = 21 },
            mqtt = { enabled = false, port = 1883 },
            discovery = { enabled = true, interval = 30 }
        },
        cache = {
            dns_ttl = 300,
            arp_ttl = 600,
            route_ttl = 3600
        },
        logging = {
            enabled = true,
            level = "info",
            file = "/var/log/netd.log",
            max_size = 10000
        },
        advanced = {
            packet_queue_size = 100,
            connection_timeout = 30,
            max_connections = 50,
            broadcast_interval = 30,
            enable_forwarding = false,
            enable_nat = false
        },
        interfaces = {
            lo = {
                name = "lo",
                type = "loopback",
                ip = "127.0.0.1",
                netmask = "255.0.0.0",
                mac = "00:00:00:00:00:00",
                status = "up",
                mtu = 65536
            },
            eth0 = {
                name = "eth0",
                type = "ethernet",
                ip = ip,
                netmask = "255.255.0.0",
                mac = mac,
                gateway = "10.0.0.1",
                status = "up",
                mtu = 1500
            }
        },
        routes = {
            {
                destination = "0.0.0.0",
                gateway = "10.0.0.1",
                genmask = "0.0.0.0",
                interface = "eth0",
                metric = 100,
                flags = "UG"
            },
            {
                destination = "10.0.0.0",
                gateway = "0.0.0.0",
                genmask = "255.255.0.0",
                interface = "eth0",
                metric = 0,
                flags = "U"
            },
            {
                destination = "127.0.0.0",
                gateway = "0.0.0.0",
                genmask = "255.0.0.0",
                interface = "lo",
                metric = 0,
                flags = "U"
            }
        }
    }
end

-- Save configuration to file
local function saveConfig(config, path)
    local file = fs.open(path, "w")
    if file then
        file.write("-- Auto-generated network configuration\n")
        file.write("-- Generated: " .. os.date() .. "\n\n")
        file.write("return " .. textutils.serialize(config))
        file.close()
        return true
    end
    return false
end

-- Load or generate network configuration
local function setupNetworkConfig()
    local configPath = "/config/network.cfg"
    local persistPath = "/etc/network.persistent"

    -- Check if we have a persistent configuration
    if fileExists(persistPath) then
        print("Loading persistent network configuration...")
        local file = fs.open(persistPath, "r")
        if file then
            local data = file.readAll()
            file.close()

            -- Parse the configuration
            local func, err = loadstring(data)
            if func then
                local config = func()
                if config then
                    -- Save to active config
                    if saveConfig(config, configPath) then
                        print("Network configuration loaded")
                        return true
                    end
                end
            end
        end
    end

    -- Generate new configuration if none exists
    if not fileExists(configPath) then
        print("Generating network configuration...")

        local computerId = os.getComputerID()
        local computerLabel = os.getComputerLabel() or ""

        -- Generate configuration
        local config = generateNetworkConfig(computerId, computerLabel)

        -- Write configuration
        if saveConfig(config, configPath) then
            -- Save persistent copy
            saveConfig(config, persistPath)
            print("Network configuration generated")
            return true
        end
    end

    return fileExists(configPath)
end

-- Start network daemon
local function startNetd()
    if not fileExists("/bin/netd.lua") then
        print("Warning: netd not found at /bin/netd.lua")
        return false
    end

    -- Check if already running
    if fileExists("/var/run/netd.pid") then
        print("netd appears to be already running")
        return true
    end

    print("Starting network daemon...")

    if STARTUP_CONFIG.netdBackground then
        -- Start in background using shell
        shell.run("bg", "/bin/netd.lua")
        print("netd started in background")
    else
        -- Start in foreground (blocks)
        shell.run("/bin/netd.lua")
    end

    return true
end

-- Show network information
local function showNetworkInfo()
    local configPath = "/config/network.cfg"
    if fileExists(configPath) then
        local func, err = loadstring("return " .. fs.open(configPath, "r").readAll())
        if func then
            local cfg = func()
            if cfg then
                print()
                print("Network Information:")
                print("  Computer ID: " .. tostring(cfg.id))
                print("  Hostname:    " .. tostring(cfg.hostname))
                print("  IP Address:  " .. tostring(cfg.ipv4))
                print("  MAC Address: " .. tostring(cfg.mac))
                print("  Gateway:     " .. tostring(cfg.gateway))
                print()
            end
        end
    end
end

-- Open modem for rednet
local function openModem()
    -- Find and open modem for rednet
    local modem = peripheral.find("modem")
    if modem then
        local side = peripheral.getName(modem)
        rednet.open(side)
        print("Modem opened on side: " .. side)
        return true
    else
        print("Warning: No modem found - local network features disabled")
        return false
    end
end

-- Main startup function
local function main()
    printBanner()

    -- Create required directories
    createDirectories()

    -- Setup network configuration
    if not setupNetworkConfig() then
        print("ERROR: Failed to setup network configuration")
        return
    end

    -- Open modem for local network
    openModem()

    -- Small delay before starting services
    if STARTUP_CONFIG.startupDelay > 0 then
        sleep(STARTUP_CONFIG.startupDelay)
    end

    -- Start network daemon if enabled
    if STARTUP_CONFIG.enableNetd then
        startNetd()
    end

    -- Show network info if enabled
    if STARTUP_CONFIG.showNetInfo then
        showNetworkInfo()
    end

    -- Run user startup file if it exists
    if fileExists("/user_startup.lua") then
        print("Running user startup...")
        shell.run("/user_startup.lua")
    end

    print("Startup complete!")
    print()
end

-- Run startup
main()