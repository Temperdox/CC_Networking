-- /router_startup.lua
-- Router/Modem startup script for ComputerCraft
-- Configures computer as a network router with firewall capabilities

local ROUTER_VERSION = "2.0.0"

-- Configuration paths
local ROUTER_CONFIG_PATH = "/etc/router.cfg"
local FIREWALL_RULES_PATH = "/etc/firewall.rules"
local WIRELESS_CONFIG_PATH = "/etc/wireless.cfg"
local DHCP_LEASES_PATH = "/var/lib/dhcp/leases"

-- Default configuration
local DEFAULT_CONFIG = {
    -- Router identification
    hostname = "router-" .. os.getComputerID(),
    mode = "router", -- "router", "bridge", "access_point"

    -- LAN Configuration
    lan = {
        interface = "eth0",
        ip = "192.168.1.1",
        netmask = "255.255.255.0",
        dhcp = {
            enabled = true,
            start = "192.168.1.100",
            ["end"] = "192.168.1.200",
            lease_time = 86400, -- 24 hours
            dns = {"192.168.1.1", "8.8.8.8"}
        }
    },

    -- WAN Configuration
    wan = {
        interface = "eth1",
        mode = "dhcp", -- "dhcp", "static", "pppoe"
        ip = nil, -- Set if static
        netmask = nil,
        gateway = nil,
        dns = {"8.8.8.8", "8.8.4.4"}
    },

    -- Wireless Configuration
    wireless = {
        enabled = false,
        ssid = "CCNet-" .. os.getComputerID(),
        security = "WPA3", -- "open", "WPA2", "WPA3"
        password = nil, -- Will be generated
        channel = 6,
        hidden = false,
        max_clients = 32
    },

    -- Firewall Configuration
    firewall = {
        enabled = true,
        default_policy = "DROP", -- Default policy for incoming
        nat_enabled = true,
        upnp_enabled = false,
        port_forwards = {},
        dmz_host = nil,
        blocked_ips = {},
        blocked_macs = {},
        allowed_services = {"dns", "dhcp", "http", "https"}
    },

    -- Services
    services = {
        dns = {enabled = true, port = 53},
        dhcp = {enabled = true, port = 67},
        web_admin = {enabled = true, port = 8080},
        ssh = {enabled = false, port = 22},
        vpn = {enabled = false, port = 1194}
    },

    -- Logging
    logging = {
        enabled = true,
        level = "info",
        file = "/var/log/router.log"
    }
}

-- Helper functions
local function printBanner()
    term.clear()
    term.setCursorPos(1, 1)
    print("=====================================")
    print(" ComputerCraft Router v" .. ROUTER_VERSION)
    print("=====================================")
    print()
end

local function generatePassword(length)
    length = length or 16
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*"
    local password = ""
    for i = 1, length do
        local idx = math.random(1, #chars)
        password = password .. chars:sub(idx, idx)
    end
    return password
end

local function fileExists(path)
    return fs.exists(path)
end

local function createDirectories()
    local dirs = {
        "/etc",
        "/var",
        "/var/lib",
        "/var/lib/dhcp",
        "/var/log",
        "/var/run",
        "/var/cache",
        "/usr",
        "/usr/lib",
        "/usr/lib/firewall"
    }

    for _, dir in ipairs(dirs) do
        if not fs.exists(dir) then
            fs.makeDir(dir)
        end
    end
end

local function detectInterfaces()
    local interfaces = {}

    -- Detect modems
    local sides = {"top", "bottom", "left", "right", "front", "back"}
    local wiredCount = 0
    local wirelessCount = 0

    for _, side in ipairs(sides) do
        if peripheral.isPresent(side) then
            local pType = peripheral.getType(side)
            if pType == "modem" then
                local modem = peripheral.wrap(side)
                if modem.isWireless and modem.isWireless() then
                    wirelessCount = wirelessCount + 1
                    interfaces["wlan" .. (wirelessCount - 1)] = {
                        side = side,
                        type = "wireless",
                        modem = modem
                    }
                else
                    wiredCount = wiredCount + 1
                    interfaces["eth" .. (wiredCount - 1)] = {
                        side = side,
                        type = "wired",
                        modem = modem
                    }
                end
            end
        end
    end

    return interfaces, wiredCount, wirelessCount
end

local function configureRouter()
    print("Router Configuration Wizard")
    print("===========================")
    print()

    local interfaces, wiredCount, wirelessCount = detectInterfaces()

    print("Detected interfaces:")
    for name, info in pairs(interfaces) do
        print("  " .. name .. ": " .. info.type .. " on " .. info.side)
    end
    print()

    if wiredCount == 0 and wirelessCount == 0 then
        print("ERROR: No network interfaces detected!")
        print("Please attach at least one modem.")
        return nil
    end

    local config = DEFAULT_CONFIG

    -- Setup mode
    print("Select router mode:")
    print("1. Router (NAT/Firewall)")
    print("2. Bridge (Transparent)")
    print("3. Access Point (Wireless only)")
    write("Choice [1]: ")
    local choice = read()
    if choice == "2" then
        config.mode = "bridge"
    elseif choice == "3" then
        config.mode = "access_point"
    end
    print()

    -- LAN configuration
    print("LAN Configuration:")
    write("LAN IP Address [192.168.1.1]: ")
    local lanIP = read()
    if lanIP ~= "" then
        config.lan.ip = lanIP
    end

    write("Enable DHCP server? [Y/n]: ")
    local dhcp = read()
    config.lan.dhcp.enabled = dhcp:lower() ~= "n"
    print()

    -- Wireless configuration
    if wirelessCount > 0 then
        print("Wireless Configuration:")
        write("Enable wireless? [Y/n]: ")
        local enableWifi = read()
        config.wireless.enabled = enableWifi:lower() ~= "n"

        if config.wireless.enabled then
            write("SSID [" .. config.wireless.ssid .. "]: ")
            local ssid = read()
            if ssid ~= "" then
                config.wireless.ssid = ssid
            end

            write("Security (open/WPA2/WPA3) [WPA3]: ")
            local security = read()
            if security ~= "" then
                config.wireless.security = security:upper()
            end

            if config.wireless.security ~= "OPEN" then
                write("Password (leave blank to auto-generate): ")
                local password = read("*")
                if password == "" then
                    config.wireless.password = generatePassword(16)
                    print("Generated password: " .. config.wireless.password)
                else
                    config.wireless.password = password
                end
            end
        end
        print()
    end

    -- Firewall configuration
    print("Firewall Configuration:")
    write("Enable firewall? [Y/n]: ")
    local firewall = read()
    config.firewall.enabled = firewall:lower() ~= "n"

    if config.firewall.enabled then
        write("Enable NAT? [Y/n]: ")
        local nat = read()
        config.firewall.nat_enabled = nat:lower() ~= "n"

        write("Enable UPnP? [y/N]: ")
        local upnp = read()
        config.firewall.upnp_enabled = upnp:lower() == "y"
    end
    print()

    -- Admin interface
    print("Admin Interface:")
    write("Enable web admin? [Y/n]: ")
    local webAdmin = read()
    config.services.web_admin.enabled = webAdmin:lower() ~= "n"

    if config.services.web_admin.enabled then
        write("Admin port [8080]: ")
        local port = read()
        if port ~= "" then
            config.services.web_admin.port = tonumber(port)
        end

        write("Admin password: ")
        config.admin_password = read("*")
        if config.admin_password == "" then
            config.admin_password = generatePassword(12)
            print("Generated admin password: " .. config.admin_password)
        end
    end

    return config, interfaces
end

local function saveConfig(config)
    local file = fs.open(ROUTER_CONFIG_PATH, "w")
    if file then
        file.write("-- Router Configuration\n")
        file.write("-- Generated: " .. os.date() .. "\n\n")
        file.write("return " .. textutils.serialize(config))
        file.close()
        return true
    end
    return false
end

local function createFirewallRules(config)
    local rules = {
        -- Default chains
        chains = {
            INPUT = {},
            FORWARD = {},
            OUTPUT = {},
            NAT = {},
            MANGLE = {}
        },

        -- Default policies
        policies = {
            INPUT = config.firewall.default_policy,
            FORWARD = config.firewall.default_policy,
            OUTPUT = "ACCEPT"
        }
    }

    -- Allow established connections
    table.insert(rules.chains.INPUT, {
        action = "ACCEPT",
        state = "ESTABLISHED,RELATED"
    })

    -- Allow loopback
    table.insert(rules.chains.INPUT, {
        action = "ACCEPT",
        interface = "lo"
    })

    -- Allow LAN to router
    table.insert(rules.chains.INPUT, {
        action = "ACCEPT",
        source = config.lan.ip .. "/24",
        interface = config.lan.interface
    })

    -- Allow DHCP
    if config.lan.dhcp.enabled then
        table.insert(rules.chains.INPUT, {
            action = "ACCEPT",
            protocol = "udp",
            dport = 67,
            sport = 68
        })
    end

    -- Allow DNS
    if config.services.dns.enabled then
        table.insert(rules.chains.INPUT, {
            action = "ACCEPT",
            protocol = "udp",
            dport = 53
        })
        table.insert(rules.chains.INPUT, {
            action = "ACCEPT",
            protocol = "tcp",
            dport = 53
        })
    end

    -- Allow admin interface from LAN
    if config.services.web_admin.enabled then
        table.insert(rules.chains.INPUT, {
            action = "ACCEPT",
            protocol = "tcp",
            dport = config.services.web_admin.port,
            source = config.lan.ip .. "/24"
        })
    end

    -- NAT rules
    if config.firewall.nat_enabled then
        table.insert(rules.chains.NAT, {
            action = "MASQUERADE",
            source = config.lan.ip .. "/24",
            output = config.wan.interface
        })
    end

    -- Port forwards
    for _, forward in ipairs(config.firewall.port_forwards or {}) do
        table.insert(rules.chains.NAT, {
            action = "DNAT",
            protocol = forward.protocol,
            dport = forward.external_port,
            ["to-destination"] = forward.internal_ip .. ":" .. forward.internal_port
        })

        table.insert(rules.chains.FORWARD, {
            action = "ACCEPT",
            protocol = forward.protocol,
            dport = forward.internal_port,
            destination = forward.internal_ip
        })
    end

    -- DMZ
    if config.firewall.dmz_host then
        table.insert(rules.chains.NAT, {
            action = "DNAT",
            ["to-destination"] = config.firewall.dmz_host
        })

        table.insert(rules.chains.FORWARD, {
            action = "ACCEPT",
            destination = config.firewall.dmz_host
        })
    end

    -- Block lists
    for _, ip in ipairs(config.firewall.blocked_ips or {}) do
        table.insert(rules.chains.INPUT, {
            action = "DROP",
            source = ip
        })
    end

    for _, mac in ipairs(config.firewall.blocked_macs or {}) do
        table.insert(rules.chains.INPUT, {
            action = "DROP",
            ["mac-source"] = mac
        })
    end

    -- Save rules
    local file = fs.open(FIREWALL_RULES_PATH, "w")
    if file then
        file.write("-- Firewall Rules\n")
        file.write("-- Generated: " .. os.date() .. "\n\n")
        file.write("return " .. textutils.serialize(rules))
        file.close()
    end

    return rules
end

local function installRouterServices()
    -- Install router daemon
    local routerd = fs.open("/bin/routerd.lua", "w")
    if routerd then
        routerd.write('-- Router daemon stub\n')
        routerd.write('shell.run("/usr/lib/router/routerd.lua")\n')
        routerd.close()
    end

    -- Create service files
    if not fs.exists("/usr/lib/router") then
        fs.makeDir("/usr/lib/router")
    end
end

-- Main setup
local function main()
    printBanner()

    createDirectories()

    -- Check if already configured
    if fileExists(ROUTER_CONFIG_PATH) then
        print("Router already configured.")
        write("Reconfigure? [y/N]: ")
        local reconfigure = read()
        if reconfigure:lower() ~= "y" then
            print("Starting router services...")
            shell.run("/bin/routerd.lua")
            return
        end
    end

    -- Configure router
    local config, interfaces = configureRouter()
    if not config then
        print("Router configuration failed!")
        return
    end

    -- Save configuration
    print()
    print("Saving configuration...")
    if not saveConfig(config) then
        print("ERROR: Failed to save configuration!")
        return
    end

    -- Create firewall rules
    print("Creating firewall rules...")
    createFirewallRules(config)

    -- Install services
    print("Installing router services...")
    installRouterServices()

    -- Create the main router daemon
    shell.run("/usr/lib/router/install.lua")

    print()
    print("Router configuration complete!")
    print()
    print("Network Summary:")
    print("  LAN IP: " .. config.lan.ip)
    if config.wireless.enabled then
        print("  WiFi SSID: " .. config.wireless.ssid)
        if config.wireless.password then
            print("  WiFi Password: " .. config.wireless.password)
        end
    end
    if config.services.web_admin.enabled then
        print("  Admin URL: http://" .. config.lan.ip .. ":" .. config.services.web_admin.port)
        if config.admin_password then
            print("  Admin Password: " .. config.admin_password)
        end
    end
    print()
    print("Starting router services...")
    shell.run("/bin/routerd.lua")
end

main()