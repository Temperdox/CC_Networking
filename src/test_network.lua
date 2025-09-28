-- /tests/test_network.lua
-- Simple wrapper to load the launcher & client safely.

local function tryLoad(path)
    if not fs.exists(path) then return false, "missing: " .. path end
    -- Use dofile instead of loadfile(..., {}, ...) so module code sees the normal globals (incl. `require`)
    return pcall(dofile, path)
end

term.clear()
term.setCursorPos(1,1)
print("Loading Test Components")
print(("="):rep(60))

local okL, launcher = tryLoad("/tests/servers/launcher.lua")
if okL then
    print("Server launcher: Loaded")
else
    print("Server launcher: Failed to load")
    print("Error: " .. tostring(launcher))
end

local okC, client = tryLoad("/tests/test_client.lua")
if okC then
    print("Test client: Loaded")
else
    print("Test client: Failed to load")
    print("Error: " .. tostring(client))
end

print()
print("Press any key to continue...")
os.pullEvent("key")
