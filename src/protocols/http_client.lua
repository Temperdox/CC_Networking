-- protocols/http_client.lua
local PROTOCOL_NAMES = require("protocols.protocol_names") or error("Protocol Names Enum not available")
local STATUSES = require("protocols.statuses") or error("Statuses Enum not available")
local Logger = require("util.logger")
local NetworkAdapter = require("protocols.network_adapter")

local HTTPClient = {}
HTTPClient.__index = HTTPClient
HTTPClient.PROTOCOL_NAME = PROTOCOL_NAMES.http
HTTPClient.SUPPORTED_METHODS = {
    "get",
    "post",
    "put",
    "delete",
    "head",
    "options",
    "patch",
    "request",
}

-- Create a shared logger for all HTTP instances
HTTPClient.logger = Logger and Logger:new({
    title = "HTTP Protocol",
    logFile = "logs/http.log",
    maxLogs = 500
}) or nil

function HTTPClient:new(baseUrl, options)
    local obj = {}
    setmetatable(obj, self)

    obj.baseUrl = baseUrl or ""
    obj.options = options or {}
    obj.headers = obj.options.headers or {}
    obj.timeout = obj.options.timeout or 5
    obj.cookies = {}

    -- Network configuration
    obj.networkType = obj.options.networkType or NetworkAdapter.NETWORK_TYPES.AUTO
    obj.networkAdapter = NetworkAdapter:new(obj.networkType, {
        logger = obj.options.logger
    })

    -- Use individual logger if provided, otherwise use shared
    obj.logger = obj.options.logger or HTTPClient.logger

    if obj.logger then
        obj.logger:info("HTTP client created for base URL: %s", obj.baseUrl)
        obj.logger:debug("Network type: %s, timeout=%d", obj.networkType, obj.timeout)
    end

    return obj
end

function HTTPClient:request(method, endpoint, body, headers)
    local url = self.baseUrl .. (endpoint or "")
    local reqHeaders = {}

    if self.logger then
        local netType = self.networkAdapter:isLocalURL(url) and "local" or "remote"
        self.logger:debug("HTTP %s request to: %s (%s network)", method, url, netType)
        if body then
            self.logger:trace("Request body: %s", tostring(body))
        end
    end

    -- Merge default headers
    for k, v in pairs(self.headers) do
        reqHeaders[k] = v
    end

    -- Merge request-specific headers
    if headers then
        for k, v in pairs(headers) do
            reqHeaders[k] = v
        end
    end

    -- Add cookies to headers
    if next(self.cookies) then
        local cookieHeader = {}
        for k, v in pairs(self.cookies) do
            table.insert(cookieHeader, k .. "=" .. v)
        end
        reqHeaders["Cookie"] = table.concat(cookieHeader, "; ")
        if self.logger then
            self.logger:trace("Adding cookies: %s", reqHeaders["Cookie"])
        end
    end

    local responseBody, responseHeaders, responseCode
    local success, result, err

    -- Use NetworkAdapter for request
    if method == "GET" then
        success, result = pcall(function()
            return self.networkAdapter:httpGet(url, reqHeaders)
        end)
    elseif method == "POST" or method == "PUT" or method == "PATCH" then
        success, result = pcall(function()
            return self.networkAdapter:httpPost(url, body, reqHeaders)
        end)
    else
        -- For other methods (DELETE, HEAD, OPTIONS, etc.)
        success, result = pcall(function()
            return self.networkAdapter:httpRequest({
                url = url,
                method = method,
                headers = reqHeaders,
                body = body,
                timeout = self.timeout
            })
        end)
    end

    if not success then
        if self.logger then
            self.logger:error("HTTP request failed: %s", tostring(result))
        end
        return STATUSES.HTTP.REQUEST_FAILED, tostring(result)
    end

    if result then
        -- Handle response
        responseBody = result.readAll and result.readAll() or result.readAll
        responseCode = result.getResponseCode and result.getResponseCode() or result.code or 200
        responseHeaders = result.getResponseHeaders and result.getResponseHeaders() or result.headers or {}

        if result.close then
            result.close()
        end

        if self.logger then
            self.logger:info("HTTP %s %s - Status: %d", method, url, responseCode)
            self.logger:trace("Response body length: %d", #(responseBody or ""))
        end
    else
        if self.logger then
            self.logger:error("HTTP %s %s - No response", method, url)
        end
        return STATUSES.HTTP.NO_RESPONSE, "No response received"
    end

    -- Handle Set-Cookie headers
    if responseHeaders and responseHeaders["Set-Cookie"] then
        local cookies = responseHeaders["Set-Cookie"]
        if type(cookies) == "string" then
            cookies = {cookies}
        end
        for _, cookie in ipairs(cookies) do
            local cookieName = cookie:match("^([^=]+)")
            local cookieValue = cookie:match("=([^;]+)")
            if cookieName and cookieValue then
                self.cookies[cookieName] = cookieValue
                if self.logger then
                    self.logger:trace("Cookie set: %s=%s", cookieName, cookieValue)
                end
            end
        end
    end

    return STATUSES.HTTP.OK, {
        code = responseCode,
        body = responseBody,
        headers = responseHeaders or {},
        cookies = self.cookies,
    }
end

function HTTPClient:get(endpoint, headers)
    if self.logger then
        self.logger:debug("GET request to endpoint: %s", endpoint or "/")
    end
    return self:request("GET", endpoint, nil, headers)
end

function HTTPClient:post(endpoint, body, headers)
    if self.logger then
        self.logger:debug("POST request to endpoint: %s", endpoint or "/")
    end
    return self:request("POST", endpoint, body, headers)
end

function HTTPClient:put(endpoint, body, headers)
    if self.logger then
        self.logger:debug("PUT request to endpoint: %s", endpoint or "/")
    end
    return self:request("PUT", endpoint, body, headers)
end

function HTTPClient:delete(endpoint, headers)
    if self.logger then
        self.logger:debug("DELETE request to endpoint: %s", endpoint or "/")
    end
    return self:request("DELETE", endpoint, nil, headers)
end

function HTTPClient:head(endpoint, headers)
    if self.logger then
        self.logger:debug("HEAD request to endpoint: %s", endpoint or "/")
    end
    return self:request("HEAD", endpoint, nil, headers)
end

function HTTPClient:options(endpoint, headers)
    if self.logger then
        self.logger:debug("OPTIONS request to endpoint: %s", endpoint or "/")
    end
    return self:request("OPTIONS", endpoint, nil, headers)
end

function HTTPClient:patch(endpoint, body, headers)
    if self.logger then
        self.logger:debug("PATCH request to endpoint: %s", endpoint or "/")
    end
    return self:request("PATCH", endpoint, body, headers)
end

function HTTPClient:send(message)
    if self.logger then
        self.logger:debug("Sending message via POST to /send")
    end
    return self:post("/send", message)
end

function HTTPClient:poll()
    if self.logger then
        self.logger:trace("Polling via GET to /poll")
    end
    return self:get("/poll")
end

function HTTPClient:checkStatus()
    -- HTTP is stateless, always return connected when client exists
    return STATUSES.http_request_sent
end

function HTTPClient:close()
    if self.logger then
        self.logger:info("Closing HTTP client for: %s", self.baseUrl)
        self.logger:debug("Cleared %d cookies", #self.cookies)
    end
    self.cookies = {}
    return STATUSES.HTTP.CLOSED, "HTTP client closed"
end

-- Compatibility method for connection manager
function HTTPClient:connect()
    -- HTTP doesn't need a persistent connection
    if self.logger then
        self.logger:debug("HTTP connect called (no-op for stateless protocol)")
    end
    return true
end

-- Create HTTP server (for local network)
function HTTPClient:createServer(port, handler)
    if self.logger then
        self.logger:info("Creating HTTP server on port %d", port)
    end

    return self.networkAdapter:createServer(port, function(request)
        if self.logger then
            self.logger:debug("Server received %s request to %s", request.method, request.path)
        end

        -- Process request through handler
        local response = handler(request)

        -- Ensure response has required fields
        response.code = response.code or 200
        response.headers = response.headers or {}
        response.body = response.body or ""

        if self.logger then
            self.logger:trace("Server sending response with code %d", response.code)
        end

        return response
    end)
end

return HTTPClient