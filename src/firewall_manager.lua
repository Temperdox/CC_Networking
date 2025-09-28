-- /firewall_manager.lua
-- Firewall management tool for router

local FirewallManager = {}
FirewallManager.__index = FirewallManager

function FirewallManager:new()
    local obj = {
        config_path = "/etc/router.cfg",
        rules_path = "/etc/firewall.rules"
    }

    setmetatable(obj, self)
    return obj
end

function FirewallManager:loadConfig()
    if not fs.exists(self.config_path) then
        return nil, "Router configuration not found"
    end

    local file = fs.open(self.config_path, "r")
    local content = file.readAll()
    file.close()

    local func = loadstring(content)
    if func then
        return func()
    end

    return nil, "Invalid configuration"
end

function FirewallManager:loadRules()
    if not fs.exists(self.rules_path) then
        return nil, "Firewall rules not found"
    end

    local file = fs.open(self.rules_path, "r")
    local content = file.readAll()
    file.close()

    local func = loadstring(content)
    if func then
        return func()
    end

    return nil, "Invalid rules"
end

function FirewallManager:saveConfig(config)
    local file = fs.open(self.config_path, "w")
    if file then
        file.write("-- Router Configuration\n")
        file.write("-- Modified: " .. os.date() .. "\n\n")
        file.write("return " .. textutils.serialize(config))
        file.close()
        return true
    end
    return false
end

function FirewallManager:saveRules(rules)
    local file = fs.open(self.rules_path, "w")
    if file then
        file.write("-- Firewall Rules\n")
        file.write("-- Modified: " .. os.date() .. "\n\n")
        file.write("return " .. textutils.serialize(rules))
        file.close()
        return true
    end
    return false
end

function FirewallManager:addPortForward(protocol, external_port, internal_ip, internal_port, description)
    local config = self:loadConfig()
    if not config then
        return false, "Failed to load configuration"
    end

    if not config.firewall.port_forwards then
        config.firewall.port_forwards = {}
    end

    -- Check for conflicts
    for _, forward in ipairs(config.firewall.port_forwards) do
        if forward.protocol == protocol and forward.external_port == external_port then
            return false, "Port forward already exists"
        end
    end

    -- Add new port forward
    table.insert(config.firewall.port_forwards, {
        protocol = protocol,
        external_port = external_port,
        internal_ip = internal_ip,
        internal_port = internal_port,
        description = description or "",
        enabled = true
    })

    -- Save configuration
    if not self:saveConfig(config) then
        return false, "Failed to save configuration"
    end

    -- Update firewall rules
    self:updateFirewallRules(config)

    return true
end

function FirewallManager:removePortForward(protocol, external_port)
    local config = self:loadConfig()
    if not config then
        return false, "Failed to load configuration"
    end

    local found = false
    local new_forwards = {}

    for _, forward in ipairs(config.firewall.port_forwards or {}) do
        if not (forward.protocol == protocol and forward.external_port == external_port) then
            table.insert(new_forwards, forward)
        else
            found = true
        end
    end

    if not found then
        return false, "Port forward not found"
    end

    config.firewall.port_forwards = new_forwards

    -- Save configuration
    if not self:saveConfig(config) then
        return false, "Failed to save configuration"
    end

    -- Update firewall rules
    self:updateFirewallRules(config)

    return true
end

function FirewallManager:setDMZ(ip)
    local config = self:loadConfig()
    if not config then
        return false, "Failed to load configuration"
    end

    config.firewall.dmz_host = ip

    -- Save configuration
    if not self:saveConfig(config) then
        return false, "Failed to save configuration"
    end

    -- Update firewall rules
    self:updateFirewallRules(config)

    return true
end

function FirewallManager:removeDMZ()
    local config = self:loadConfig()
    if not config then
        return false, "Failed to load configuration"
    end

    config.firewall.dmz_host = nil

    -- Save configuration
    if not self:saveConfig(config) then
        return false, "Failed to save configuration"
    end

    -- Update firewall rules
    self:updateFirewallRules(config)

    return true
end

function FirewallManager:blockIP(ip, reason)
    local config = self:loadConfig()
    if not config then
        return false, "Failed to load configuration"
    end

    if not config.firewall.blocked_ips then
        config.firewall.blocked_ips = {}
    end

    -- Check if already blocked
    for _, blocked in ipairs(config.firewall.blocked_ips) do
        if blocked == ip or (type(blocked) == "table" and blocked.ip == ip) then
            return false, "IP already blocked"
        end
    end

    -- Add to block list
    table.insert(config.firewall.blocked_ips, {
        ip = ip,
        reason = reason or "Manual block",
        timestamp = os.epoch("utc")
    })

    -- Save configuration
    if not self:saveConfig(config) then
        return false, "Failed to save configuration"
    end

    -- Update firewall rules
    self:updateFirewallRules(config)

    return true
end

function FirewallManager:unblockIP(ip)
    local config = self:loadConfig()
    if not config then
        return false, "Failed to load configuration"
    end

    local found = false
    local new_blocked = {}

    for _, blocked in ipairs(config.firewall.blocked_ips or {}) do
        local blocked_ip = type(blocked) == "table" and blocked.ip or blocked
        if blocked_ip ~= ip then
            table.insert(new_blocked, blocked)
        else
            found = true
        end
    end

    if not found then
        return false, "IP not found in block list"
    end

    config.firewall.blocked_ips = new_blocked

    -- Save configuration
    if not self:saveConfig(config) then
        return false, "Failed to save configuration"
    end

    -- Update firewall rules
    self:updateFirewallRules(config)

    return true
end

function FirewallManager:blockMAC(mac, reason)
    local config = self:loadConfig()
    if not config then
        return false, "Failed to load configuration"
    end

    if not config.firewall.blocked_macs then
        config.firewall.blocked_macs = {}
    end

    -- Check if already blocked
    for _, blocked in ipairs(config.firewall.blocked_macs) do
        if blocked == mac or (type(blocked) == "table" and blocked.mac == mac) then
            return false, "MAC already blocked"
        end
    end

    -- Add to block list
    table.insert(config.firewall.blocked_macs, {
        mac = mac,
        reason = reason or "Manual block",
        timestamp = os.epoch("utc")
    })

    -- Save configuration
    if not self:saveConfig(config) then
        return false, "Failed to save configuration"
    end

    -- Update firewall rules
    self:updateFirewallRules(config)

    return true
end

function FirewallManager:unblockMAC(mac)
    local config = self:loadConfig()
    if not config then
        return false, "Failed to load configuration"
    end

    local found = false
    local new_blocked = {}

    for _, blocked in ipairs(config.firewall.blocked_macs or {}) do
        local blocked_mac = type(blocked) == "table" and blocked.mac or blocked
        if blocked_mac ~= mac then
            table.insert(new_blocked, blocked)
        else
            found = true
        end
    end

    if not found then
        return false, "MAC not found in block list"
    end

    config.firewall.blocked_macs = new_blocked

    -- Save configuration
    if not self:saveConfig(config) then
        return false, "Failed to save configuration"
    end

    -- Update firewall rules
    self:updateFirewallRules(config)

    return true
end

function FirewallManager:setFirewallPolicy(chain, policy)
    local valid_chains = {INPUT = true, FORWARD = true, OUTPUT = true}
    local valid_policies = {ACCEPT = true, DROP = true, REJECT = true}

    if not valid_chains[chain] then
        return false, "Invalid chain"
    end

    if not valid_policies[policy] then
        return false, "Invalid policy"
    end

    local rules = self:loadRules()
    if not rules then
        return false, "Failed to load rules"
    end

    rules.policies[chain] = policy

    -- Save rules
    if not self:saveRules(rules) then
        return false, "Failed to save rules"
    end

    return true
end

function FirewallManager:addCustomRule(chain, rule)
    local valid_chains = {INPUT = true, FORWARD = true, OUTPUT = true, NAT = true, MANGLE = true}

    if not valid_chains[chain] then
        return false, "Invalid chain"
    end

    local rules = self:loadRules()
    if not rules then
        return false, "Failed to load rules"
    end

    if not rules.chains[chain] then
        rules.chains[chain] = {}
    end

    table.insert(rules.chains[chain], rule)

    -- Save rules
    if not self:saveRules(rules) then
        return false, "Failed to save rules"
    end

    return true
end

function FirewallManager:updateFirewallRules(config)
    local rules = {
        chains = {
            INPUT = {},
            FORWARD = {},
            OUTPUT = {},
            NAT = {},
            MANGLE = {}
        },
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

    -- Block lists
    for _, blocked in ipairs(config.firewall.blocked_ips or {}) do
        local ip = type(blocked) == "table" and blocked.ip or blocked
        table.insert(rules.chains.INPUT, {
            action = "DROP",
            source = ip,
            log = true,
            log_prefix = "BLOCKED_IP"
        })
    end

    for _, blocked in ipairs(config.firewall.blocked_macs or {}) do
        local mac = type(blocked) == "table" and blocked.mac or blocked
        table.insert(rules.chains.INPUT, {
            action = "DROP",
            ["mac-source"] = mac,
            log = true,
            log_prefix = "BLOCKED_MAC"
        })
    end

    -- Port forwards
    for _, forward in ipairs(config.firewall.port_forwards or {}) do
        if forward.enabled ~= false then
            -- DNAT rule
            table.insert(rules.chains.NAT, {
                action = "DNAT",
                protocol = forward.protocol,
                dport = forward.external_port,
                ["to-destination"] = forward.internal_ip .. ":" .. forward.internal_port,
                comment = forward.description
            })

            -- Forward rule
            table.insert(rules.chains.FORWARD, {
                action = "ACCEPT",
                protocol = forward.protocol,
                dport = forward.internal_port,
                destination = forward.internal_ip,
                comment = forward.description
            })
        end
    end

    -- DMZ
    if config.firewall.dmz_host then
        table.insert(rules.chains.NAT, {
            action = "DNAT",
            ["to-destination"] = config.firewall.dmz_host,
            comment = "DMZ Host"
        })

        table.insert(rules.chains.FORWARD, {
            action = "ACCEPT",
            destination = config.firewall.dmz_host,
            comment = "DMZ Host"
        })
    end

    -- NAT masquerading
    if config.firewall.nat_enabled then
        table.insert(rules.chains.NAT, {
            action = "MASQUERADE",
            source = config.lan.ip .. "/24",
            output = config.wan.interface,
            comment = "NAT Masquerading"
        })
    end

    -- UPnP rules (if enabled)
    if config.firewall.upnp_enabled then
        table.insert(rules.chains.INPUT, {
            action = "ACCEPT",
            protocol = "udp",
            dport = 1900,
            comment = "UPnP Discovery"
        })
    end

    self:saveRules(rules)

    -- Reload firewall if daemon is running
    if fs.exists("/var/run/routerd.pid") then
        -- Send reload signal
        os.queueEvent("firewall_reload")
    end

    return true
end

function FirewallManager:listPortForwards()
    local config = self:loadConfig()
    if not config then
        return nil, "Failed to load configuration"
    end

    return config.firewall.port_forwards or {}
end

function FirewallManager:listBlockedIPs()
    local config = self:loadConfig()
    if not config then
        return nil, "Failed to load configuration"
    end

    return config.firewall.blocked_ips or {}
end

function FirewallManager:listBlockedMACs()
    local config = self:loadConfig()
    if not config then
        return nil, "Failed to load configuration"
    end

    return config.firewall.blocked_macs or {}
end

function FirewallManager:getStatistics()
    if fs.exists("/var/run/router.stats") then
        local file = fs.open("/var/run/router.stats", "r")
        if file then
            local content = file.readAll()
            file.close()
            return textutils.unserialize(content)
        end
    end
    return nil
end

-- Interactive management interface
local function main()
    local manager = FirewallManager:new()

    local function printMenu()
        print("\n=== Firewall Manager ===")
        print("1. Port Forwarding")
        print("2. DMZ Settings")
        print("3. IP Blocking")
        print("4. MAC Blocking")
        print("5. Firewall Policies")
        print("6. View Statistics")
        print("7. Reload Firewall")
        print("0. Exit")
        print()
        write("Choice: ")
    end

    while true do
        printMenu()
        local choice = read()

        if choice == "1" then
            -- Port forwarding menu
            print("\n=== Port Forwarding ===")
            print("1. Add port forward")
            print("2. Remove port forward")
            print("3. List port forwards")
            write("Choice: ")

            local subchoice = read()

            if subchoice == "1" then
                print("\nAdd Port Forward:")
                write("Protocol (tcp/udp): ")
                local protocol = read()
                write("External port: ")
                local ext_port = tonumber(read())
                write("Internal IP: ")
                local int_ip = read()
                write("Internal port: ")
                local int_port = tonumber(read())
                write("Description: ")
                local desc = read()

                local success, err = manager:addPortForward(
                        protocol, ext_port, int_ip, int_port, desc
                )

                if success then
                    print("Port forward added successfully")
                else
                    print("Error: " .. err)
                end

            elseif subchoice == "2" then
                print("\nRemove Port Forward:")
                write("Protocol (tcp/udp): ")
                local protocol = read()
                write("External port: ")
                local ext_port = tonumber(read())

                local success, err = manager:removePortForward(protocol, ext_port)

                if success then
                    print("Port forward removed successfully")
                else
                    print("Error: " .. err)
                end

            elseif subchoice == "3" then
                print("\nPort Forwards:")
                local forwards = manager:listPortForwards()

                if #forwards == 0 then
                    print("No port forwards configured")
                else
                    for _, fwd in ipairs(forwards) do
                        print(string.format("%s:%d -> %s:%d (%s) %s",
                                fwd.protocol:upper(),
                                fwd.external_port,
                                fwd.internal_ip,
                                fwd.internal_port,
                                fwd.description or "",
                                fwd.enabled == false and "[DISABLED]" or ""
                        ))
                    end
                end
            end

        elseif choice == "2" then
            -- DMZ settings
            print("\n=== DMZ Settings ===")
            print("1. Set DMZ host")
            print("2. Remove DMZ host")
            print("3. View DMZ host")
            write("Choice: ")

            local subchoice = read()

            if subchoice == "1" then
                write("DMZ host IP: ")
                local ip = read()

                local success, err = manager:setDMZ(ip)

                if success then
                    print("DMZ host set successfully")
                else
                    print("Error: " .. err)
                end

            elseif subchoice == "2" then
                local success, err = manager:removeDMZ()

                if success then
                    print("DMZ host removed")
                else
                    print("Error: " .. err)
                end

            elseif subchoice == "3" then
                local config = manager:loadConfig()
                if config and config.firewall.dmz_host then
                    print("DMZ Host: " .. config.firewall.dmz_host)
                else
                    print("No DMZ host configured")
                end
            end

        elseif choice == "3" then
            -- IP blocking
            print("\n=== IP Blocking ===")
            print("1. Block IP")
            print("2. Unblock IP")
            print("3. List blocked IPs")
            write("Choice: ")

            local subchoice = read()

            if subchoice == "1" then
                write("IP to block: ")
                local ip = read()
                write("Reason: ")
                local reason = read()

                local success, err = manager:blockIP(ip, reason)

                if success then
                    print("IP blocked successfully")
                else
                    print("Error: " .. err)
                end

            elseif subchoice == "2" then
                write("IP to unblock: ")
                local ip = read()

                local success, err = manager:unblockIP(ip)

                if success then
                    print("IP unblocked successfully")
                else
                    print("Error: " .. err)
                end

            elseif subchoice == "3" then
                print("\nBlocked IPs:")
                local blocked = manager:listBlockedIPs()

                if #blocked == 0 then
                    print("No IPs blocked")
                else
                    for _, entry in ipairs(blocked) do
                        if type(entry) == "table" then
                            print(string.format("%s - %s",
                                    entry.ip, entry.reason or ""))
                        else
                            print(entry)
                        end
                    end
                end
            end

        elseif choice == "4" then
            -- MAC blocking
            print("\n=== MAC Blocking ===")
            print("1. Block MAC")
            print("2. Unblock MAC")
            print("3. List blocked MACs")
            write("Choice: ")

            local subchoice = read()

            if subchoice == "1" then
                write("MAC to block: ")
                local mac = read()
                write("Reason: ")
                local reason = read()

                local success, err = manager:blockMAC(mac, reason)

                if success then
                    print("MAC blocked successfully")
                else
                    print("Error: " .. err)
                end

            elseif subchoice == "2" then
                write("MAC to unblock: ")
                local mac = read()

                local success, err = manager:unblockMAC(mac)

                if success then
                    print("MAC unblocked successfully")
                else
                    print("Error: " .. err)
                end

            elseif subchoice == "3" then
                print("\nBlocked MACs:")
                local blocked = manager:listBlockedMACs()

                if #blocked == 0 then
                    print("No MACs blocked")
                else
                    for _, entry in ipairs(blocked) do
                        if type(entry) == "table" then
                            print(string.format("%s - %s",
                                    entry.mac, entry.reason or ""))
                        else
                            print(entry)
                        end
                    end
                end
            end

        elseif choice == "5" then
            -- Firewall policies
            print("\n=== Firewall Policies ===")

            local rules = manager:loadRules()
            if rules and rules.policies then
                print("Current policies:")
                for chain, policy in pairs(rules.policies) do
                    print("  " .. chain .. ": " .. policy)
                end
            end

            print("\nChange policy:")
            write("Chain (INPUT/FORWARD/OUTPUT): ")
            local chain = read():upper()
            write("Policy (ACCEPT/DROP/REJECT): ")
            local policy = read():upper()

            local success, err = manager:setFirewallPolicy(chain, policy)

            if success then
                print("Policy updated successfully")
            else
                print("Error: " .. err)
            end

        elseif choice == "6" then
            -- View statistics
            print("\n=== Router Statistics ===")

            local stats = manager:getStatistics()
            if stats then
                print("Packets Forwarded: " .. stats.packets_forwarded)
                print("Packets Dropped: " .. stats.packets_dropped)
                print("Packets NAT: " .. stats.packets_nat)
                print("Bytes RX: " .. stats.bytes_rx)
                print("Bytes TX: " .. stats.bytes_tx)

                local uptime = os.epoch("utc") - stats.uptime_start
                print("Uptime: " .. math.floor(uptime / 1000) .. " seconds")
            else
                print("No statistics available")
            end

        elseif choice == "7" then
            -- Reload firewall
            print("Reloading firewall...")
            os.queueEvent("firewall_reload")
            print("Firewall reload signal sent")

        elseif choice == "0" then
            break
        end

        print("\nPress any key to continue...")
        os.pullEvent("key")
    end
end

-- Run if executed directly
if not ... then
    main()
end

return FirewallManager