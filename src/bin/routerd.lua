#!/usr/bin/env lua
-- /bin/routerd.lua
-- Router daemon stub - calls the actual router daemon

-- Check if router is configured
if not fs.exists("/etc/router.cfg") then
    print("[routerd] Error: Router not configured")
    print("[routerd] Please run /router_startup.lua to configure the router")
    return
end

-- Check if actual daemon exists
if not fs.exists("/usr/lib/router/routerd.lua") then
    print("[routerd] Error: Router daemon not installed")
    print("[routerd] Please run /router_startup.lua to install router components")
    return
end

-- Run the actual router daemon
shell.run("/usr/lib/router/routerd.lua")