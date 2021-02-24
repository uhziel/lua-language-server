local net      = require 'service.net'
local client   = require 'provider.client'
local nonil    = require 'without-check-nil'
local util     = require 'utility'

local tokenPath = (ROOT / 'log' / 'token'):string()
local token = util.loadFile(tokenPath)
if not token then
    token = ('%016X'):format(math.random(0, math.maxinteger))
    util.saveFile(tokenPath, token)
end

log.info('Telemetry Token:', token)

local function getClientName()
    nonil.enable()
    local clientName    = client.info.clientInfo.name
    local clientVersion = client.info.clientInfo.version
    nonil.disable()
    local data = table.concat({clientName, clientVersion}, ' ')
    data = string.gsub(data, ' ', '%%20')
    return data
end

local function send(link, msg)
    link:write(msg)
end

local GET_METHOD_TMP = [[
GET %s HTTP/1.1
Host: %s:%s

]]

local function  pushClientInfo(link)
    local hostIp, hostPort = link._fd:info('peer');
    local clientIp, clientPort = link._fd:info('socket');
    local url = string.format('/pulse?token=%s&clientname=%s&&clientip=%s', token, getClientName(), clientIp)
    local data = string.format(GET_METHOD_TMP, url, hostIp, hostPort)
    send(link, data)
end

local m = {}

function m.report()
    local suc, link = pcall(net.connect, 'tcp', '192.168.1.133', 11577)
    if not suc or not link then
        return
    end
    function link:on_connect()
        pushClientInfo(link)
        self:close()
    end
end

return m
