-- /router_monitor.lua
-- Router monitoring tool with real-time statistics

local REFRESH_RATE = 1 -- seconds

local function formatBytes(bytes)
    if bytes < 1024 then
        return string.format("%d B", bytes)
    elseif bytes < 1024 * 1024 then
        return string.format("%.2f KB", bytes / 1024)
    elseif bytes < 1024 * 1024 * 1024 then
        return string.format("%.2f MB", bytes / (1024 * 1024))
    else
        return string.format("%.2f GB", bytes / (1024 * 1024 * 1024))
    end
end

local function formatUptime(ms)
    local seconds = math.floor(ms / 1000)
    local minutes = math.floor(seconds / 60)
    local hours = math.floor(minutes / 60)
    local days = math.floor(hours / 24)

    if days > 0 then
        return string.format("%dd %dh %dm", days, hours % 24, minutes % 60)
    elseif hours > 0 then
        return string.format("%dh %dm %ds", hours, minutes % 60, seconds % 60)
    elseif minutes > 0 then
        return string.format("%dm %ds", minutes, seconds % 60)
    else
        return string.format("%ds", seconds)
    end
end

local function loadStats()
    local stats = {}
    if fs.exists("/var/run/router.stats") then
        local file = fs.open("/var/run/router.stats", "r")
        if file then
            local content = file.readAll()
            file.close()
            stats = textutils.unserialize(content) or {}
        end
    end
    return stats
end

local function loadLeases()
    local leases = {}
    if fs.exists("/var/lib/dhcp/leases") then
        local file = fs.open("/var/lib/dhcp/leases", "r")
        if file then
            local content = file.readAll()
            file.close()
            leases = textutils.unserialize(content) or {}
        end
    end
    return leases
end

local function loadConfig()
    if fs.exists("/etc/router.cfg") then
        local file = fs.open("/etc/router.cfg", "r")
        if file then
            local content = file.readAll()
            file.close()
            local func = loadstring(content)
            if func then
                return func()
            end
        end
    end
    return nil
end

local function drawHeader()
    term.setTextColor(colors.white)
    term.setBackgroundColor(colors.blue)
    term.setCursorPos(1, 1)
    term.clearLine()
    local title = "Router Monitor v1.0"
    term.setCursorPos(math.floor((term.getSize() - #title) / 2), 1)
    term.write(title)
    term.setBackgroundColor(colors.black)
end

local function drawStats(y, stats, config)
    local x = 2

    -- Calculate uptime
    local uptime = 0
    if stats.uptime_start then
        uptime = os.epoch("utc") - stats.uptime_start
    end

    -- Router info
    term.setTextColor(colors.yellow)
    term.setCursorPos(x, y)
    term.write("=== Router Status ===")

    term.setTextColor(colors.white)
    term.setCursorPos(x, y + 1)
    term.write("Hostname: " .. (config and config.hostname or "Unknown"))

    term.setCursorPos(x, y + 2)
    term.write("LAN IP: " .. (config and config.lan and config.lan.ip or "N/A"))

    term.setCursorPos(x, y + 3)
    term.write("Uptime: " .. formatUptime(uptime))

    -- Traffic statistics
    term.setTextColor(colors.yellow)
    term.setCursorPos(x, y + 5)
    term.write("=== Traffic ===")

    term.setTextColor(colors.white)
    term.setCursorPos(x, y + 6)
    term.write("RX: " .. formatBytes(stats.bytes_rx or 0))

    term.setCursorPos(x, y + 7)
    term.write("TX: " .. formatBytes(stats.bytes_tx or 0))

    -- Packet statistics
    term.setTextColor(colors.yellow)
    term.setCursorPos(x, y + 9)
    term.write("=== Packets ===")

    term.setTextColor(colors.white)
    term.setCursorPos(x, y + 10)
    term.write("Forwarded: " .. (stats.packets_forwarded or 0))

    term.setCursorPos(x, y + 11)
    term.write("Dropped: " .. (stats.packets_dropped or 0))

    term.setCursorPos(x, y + 12)
    term.write("NAT: " .. (stats.packets_nat or 0))

    -- Calculate and show rates
    if stats.last_update then
        local time_diff = (os.epoch("utc") - stats.last_update) / 1000
        if time_diff > 0 and stats.last_bytes_rx and stats.last_bytes_tx then
            local rx_rate = (stats.bytes_rx - stats.last_bytes_rx) / time_diff
            local tx_rate = (stats.bytes_tx - stats.last_bytes_tx) / time_diff

            term.setTextColor(colors.lightGray)
            term.setCursorPos(x + 20, y + 6)
            term.write("(" .. formatBytes(rx_rate) .. "/s)")

            term.setCursorPos(x + 20, y + 7)
            term.write("(" .. formatBytes(tx_rate) .. "/s)")
        end
    end
end

local function drawLeases(y, leases)
    local x = 2

    term.setTextColor(colors.yellow)
    term.setCursorPos(x, y)
    term.write("=== DHCP Leases ===")

    term.setTextColor(colors.white)

    local count = 0
    local maxDisplay = 8

    for mac, lease in pairs(leases) do
        if count < maxDisplay then
            term.setCursorPos(x, y + 1 + count)

            local hostname = lease.hostname or mac:sub(1, 17)
            local ip = lease.ip or "?.?.?.?"

            -- Calculate remaining time
            local remaining = ""
            if lease.expires then
                local ttl = lease.expires - os.epoch("utc")
                if ttl > 0 then
                    remaining = " (" .. formatUptime(ttl) .. ")"
                else
                    remaining = " (expired)"
                end
            end

            local line = string.format("%-15s -> %-15s%s",
                    hostname:sub(1, 15), ip, remaining)

            term.write(line:sub(1, term.getSize() - 4))
            count = count + 1
        end
    end

    if count == 0 then
        term.setCursorPos(x, y + 1)
        term.setTextColor(colors.lightGray)
        term.write("No active leases")
    elseif count < #leases then
        term.setCursorPos(x, y + 1 + count)
        term.setTextColor(colors.lightGray)
        term.write("... and " .. (#leases - count) .. " more")
    end
end

local function drawFooter()
    local width, height = term.getSize()

    term.setTextColor(colors.white)
    term.setBackgroundColor(colors.gray)
    term.setCursorPos(1, height)
    term.clearLine()

    local controls = "Q: Quit | R: Refresh | F: Firewall | C: Clear Stats"
    term.setCursorPos(2, height)
    term.write(controls:sub(1, width - 2))

    term.setBackgroundColor(colors.black)
end

local function clearStats()
    -- Reset statistics file
    local stats = loadStats()
    stats.packets_forwarded = 0
    stats.packets_dropped = 0
    stats.packets_nat = 0
    stats.bytes_rx = 0
    stats.bytes_tx = 0
    stats.uptime_start = os.epoch("utc")

    local file = fs.open("/var/run/router.stats", "w")
    if file then
        file.write(textutils.serialize(stats))
        file.close()
    end
end

local function showFirewallInfo()
    term.clear()
    drawHeader()

    term.setTextColor(colors.yellow)
    term.setCursorPos(2, 3)
    term.write("=== Firewall Status ===")

    term.setTextColor(colors.white)

    -- Load firewall rules
    if fs.exists("/etc/firewall.rules") then
        local file = fs.open("/etc/firewall.rules", "r")
        if file then
            local content = file.readAll()
            file.close()

            local func = loadstring(content)
            if func then
                local rules = func()

                term.setCursorPos(2, 5)
                term.write("Policies:")

                local y = 6
                for chain, policy in pairs(rules.policies or {}) do
                    term.setCursorPos(4, y)
                    term.write(chain .. ": " .. policy)
                    y = y + 1
                end

                y = y + 1
                term.setCursorPos(2, y)
                term.write("Rule Counts:")
                y = y + 1

                for chain, chain_rules in pairs(rules.chains or {}) do
                    term.setCursorPos(4, y)
                    term.write(chain .. ": " .. #chain_rules .. " rules")
                    y = y + 1
                end
            end
        end
    else
        term.setCursorPos(2, 5)
        term.setTextColor(colors.red)
        term.write("Firewall rules not found")
    end

    term.setTextColor(colors.lightGray)
    local _, height = term.getSize()
    term.setCursorPos(2, height - 1)
    term.write("Press any key to return...")

    os.pullEvent("key")
end

local function monitor()
    -- Check if router is configured
    local config = loadConfig()
    if not config then
        print("Router is not configured!")
        print("Please run /router_startup.lua first")
        return
    end

    -- Check if router daemon is running
    if not fs.exists("/var/run/routerd.pid") then
        print("Router daemon is not running!")
        print("Starting router daemon...")
        shell.run("bg /bin/routerd.lua")
        sleep(2)
    end

    local lastStats = {}
    local running = true

    while running do
        -- Load current data
        local stats = loadStats()
        local leases = loadLeases()

        -- Store last values for rate calculation
        stats.last_bytes_rx = lastStats.bytes_rx
        stats.last_bytes_tx = lastStats.bytes_tx
        stats.last_update = lastStats.update_time

        -- Clear screen and draw interface
        term.clear()
        drawHeader()
        drawStats(3, stats, config)
        drawLeases(17, leases)
        drawFooter()

        -- Store current stats
        lastStats = stats
        lastStats.update_time = os.epoch("utc")

        -- Handle input with timeout
        local timer = os.startTimer(REFRESH_RATE)
        while true do
            local event, param1 = os.pullEvent()

            if event == "timer" and param1 == timer then
                break -- Refresh display

            elseif event == "char" then
                local key = param1:lower()

                if key == "q" then
                    running = false
                    break

                elseif key == "r" then
                    break -- Force refresh

                elseif key == "c" then
                    clearStats()
                    term.setCursorPos(2, 2)
                    term.setTextColor(colors.lime)
                    term.write("Statistics cleared!")
                    sleep(1)
                    break

                elseif key == "f" then
                    showFirewallInfo()
                    break
                end
            end
        end
    end

    -- Clear screen on exit
    term.clear()
    term.setCursorPos(1, 1)
    print("Router monitor stopped.")
end

-- Run the monitor
monitor()