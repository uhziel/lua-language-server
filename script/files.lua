local platform = require 'bee.platform'
local config   = require 'config'
local glob     = require 'glob'
local furi     = require 'file-uri'
local parser   = require 'parser'
local proto    = require 'proto'
local lang     = require 'language'
local await    = require 'await'
local timer    = require 'timer'
local plugin   = require 'plugin'
local util     = require 'utility'

local m = {}

m.openMap       = {}
m.libraryMap    = {}
m.fileMap       = {}
m.dllMap        = {}
m.watchList     = {}
m.notifyCache   = {}
m.assocVersion  = -1
m.assocMatcher  = nil
m.globalVersion = 0
m.linesMap = setmetatable({}, { __mode = 'v' })
m.astMap   = setmetatable({}, { __mode = 'v' })

local uriMap = {}
local function getUriKey(uri)
    if not uriMap[uri] then
        if platform.OS == 'Windows' then
            uriMap[uri] = uri:lower()
        else
            uriMap[uri] = uri
        end
    end
    return uriMap[uri]
end

--- 打开文件
---@param uri uri
function m.open(uri)
    local originUri = uri
    uri = getUriKey(uri)
    m.openMap[uri] = true
    m.onWatch('open', originUri)
end

--- 关闭文件
---@param uri uri
function m.close(uri)
    local originUri = uri
    uri = getUriKey(uri)
    m.openMap[uri] = nil
    m.onWatch('close', originUri)
end

--- 是否打开
---@param uri uri
---@return boolean
function m.isOpen(uri)
    uri = getUriKey(uri)
    return m.openMap[uri] == true
end

--- 标记为库文件
function m.setLibraryPath(uri, libraryPath)
    uri = getUriKey(uri)
    m.libraryMap[uri] = libraryPath
end

--- 是否是库文件
function m.isLibrary(uri)
    uri = getUriKey(uri)
    return m.libraryMap[uri] ~= nil
end

--- 获取库文件的根目录
function m.getLibraryPath(uri)
    uri = getUriKey(uri)
    return m.libraryMap[uri]
end

function m.flushAllLibrary()
    m.libraryMap = {}
end

--- 是否存在
---@return boolean
function m.exists(uri)
    uri = getUriKey(uri)
    return m.fileMap[uri] ~= nil
end

function m.asKey(uri)
    uri = getUriKey(uri)
    return uri
end

--- 设置文件文本
---@param uri uri
---@param text string
function m.setText(uri, text)
    if not text then
        return
    end
    --log.debug('setText', uri)
    local originUri = uri
    uri = getUriKey(uri)
    local create
    if not m.fileMap[uri] then
        m.fileMap[uri] = {
            uri = originUri,
            version = 0,
        }
        create = true
        m._pairsCache = nil
    end
    local suc, newText = plugin.dispatch('OnSetText', originUri, text)
    if suc then
        text = newText
    end
    local file = m.fileMap[uri]
    if file.text == text then
        return
    end
    file.text  = text
    m.linesMap[uri] = nil
    m.astMap[uri] = nil
    file.cache = {}
    file.cacheActiveTime = math.huge
    file.version = file.version + 1
    m.globalVersion = m.globalVersion + 1
    await.close('files.version')
    if create then
        m.onWatch('create', originUri)
    end
    m.onWatch('update', originUri)
end

--- 获取文件版本
function m.getVersion(uri)
    uri = getUriKey(uri)
    local file = m.fileMap[uri]
    if not file then
        return nil
    end
    return file.version
end

--- 获取文件文本
---@param uri uri
---@return string text
function m.getText(uri)
    uri = getUriKey(uri)
    local file = m.fileMap[uri]
    if not file then
        return nil
    end
    return file.text
end

--- 移除文件
---@param uri uri
function m.remove(uri)
    local originUri = uri
    uri = getUriKey(uri)
    local file = m.fileMap[uri]
    if not file then
        return
    end
    m.fileMap[uri] = nil
    m._pairsCache = nil

    m.globalVersion = m.globalVersion + 1
    await.close('files.version')
    m.onWatch('remove', originUri)
end

--- 移除所有文件
function m.removeAll()
    m.globalVersion = m.globalVersion + 1
    await.close('files.version')
    m._pairsCache = nil
    for uri in pairs(m.fileMap) do
        if not m.libraryMap[uri] then
            m.fileMap[uri]  = nil
            m.astMap[uri]   = nil
            m.linesMap[uri] = nil
            m.onWatch('remove', uri)
        end
    end
    --m.notifyCache = {}
end

--- 移除所有关闭的文件
function m.removeAllClosed()
    m.globalVersion = m.globalVersion + 1
    await.close('files.version')
    m._pairsCache = nil
    for uri in pairs(m.fileMap) do
        if  not m.openMap[uri]
        and not m.libraryMap[uri] then
            m.fileMap[uri]  = nil
            m.astMap[uri]   = nil
            m.linesMap[uri] = nil
            m.onWatch('remove', uri)
        end
    end
    --m.notifyCache = {}
end

--- 获取一个包含所有文件uri的数组
---@return uri[]
function m.getAllUris()
    local files = m._pairsCache
    local i = 0
    if not files then
        files = {}
        m._pairsCache = files
        for uri in pairs(m.fileMap) do
            i = i + 1
            files[i] = uri
        end
    end
    return m._pairsCache
end

--- 遍历文件
function m.eachFile()
    local files = m.getAllUris()
    local i = 0
    return function ()
        i = i + 1
        return files[i]
    end
end

--- Pairs dll files
---@return function
function m.eachDll()
    local map = {}
    for uri, file in pairs(m.dllMap) do
        map[uri] = file
    end
    return pairs(map)
end

function m.compileAst(uri, text)
    if not m.isOpen(uri) and #text >= config.config.workspace.preloadFileSize * 1000 then
        if not m.notifyCache['preloadFileSize'] then
            m.notifyCache['preloadFileSize'] = {}
            m.notifyCache['skipLargeFileCount'] = 0
        end
        if not m.notifyCache['preloadFileSize'][uri] then
            m.notifyCache['preloadFileSize'][uri] = true
            m.notifyCache['skipLargeFileCount'] = m.notifyCache['skipLargeFileCount'] + 1
            if m.notifyCache['skipLargeFileCount'] <= 3 then
                local ws = require 'workspace'
                proto.notify('window/showMessage', {
                    type = 3,
                    message = lang.script('WORKSPACE_SKIP_LARGE_FILE'
                        , ws.getRelativePath(uri)
                        , config.config.workspace.preloadFileSize
                        , #text / 1000
                    ),
                })
            end
        end
        return nil
    end
    local clock = os.clock()
    local state, err = parser:compile(text
        , 'lua'
        , config.config.runtime.version
        , {
            special           = config.config.runtime.special,
            unicodeName       = config.config.runtime.unicodeName,
            nonstandardSymbol = config.config.runtime.nonstandardSymbol,
        }
    )
    local passed = os.clock() - clock
    if passed > 0.1 then
        log.warn(('Compile [%s] takes [%.3f] sec, size [%.3f] kb.'):format(uri, passed, #text / 1000))
    end
    if state then
        state.uri = uri
        state.ast.uri = uri
        local clock = os.clock()
        parser:luadoc(state)
        local passed = os.clock() - clock
        if passed > 0.1 then
            log.warn(('Parse LuaDoc of [%s] takes [%.3f] sec, size [%.3f] kb.'):format(uri, passed, #text / 1000))
        end
        return state
    else
        log.error(err)
        return nil
    end
end

--- 获取文件语法树
---@param uri uri
---@return table ast
function m.getAst(uri)
    uri = getUriKey(uri)
    if uri ~= '' and not m.isLua(uri) then
        return nil
    end
    local file = m.fileMap[uri]
    if not file then
        return nil
    end
    local ast = m.astMap[uri]
    if not ast then
        ast = m.compileAst(uri, file.text)
        m.astMap[uri] = ast
    end
    file.cacheActiveTime = timer.clock()
    return ast
end

--- 获取文件行信息
---@param uri uri
---@return table lines
function m.getLines(uri)
    uri = getUriKey(uri)
    local file = m.fileMap[uri]
    if not file then
        return nil
    end
    local lines = m.linesMap[uri]
    if not lines then
        lines = parser:lines(file.text)
        m.linesMap[uri] = lines
    end
    return lines
end

--- 获取原始uri
function m.getOriginUri(uri)
    uri = getUriKey(uri)
    local file = m.fileMap[uri] or m.dllMap[uri]
    if not file then
        return nil
    end
    return file.uri
end

function m.getUri(uri)
    uri = getUriKey(uri)
    return uri
end

--- 获取文件的自定义缓存信息（在文件内容更新后自动失效）
function m.getCache(uri)
    uri = getUriKey(uri)
    local file = m.fileMap[uri]
    if not file then
        return nil
    end
    --file.cacheActiveTime = timer.clock()
    return file.cache
end

--- 判断文件名相等
function m.eq(a, b)
    if platform.OS == 'Windows' then
        return a:lower():gsub('[/\\]+', '/') == b:lower():gsub('[/\\]+', '/')
    else
        return a == b
    end
end

--- 获取文件关联
function m.getAssoc()
    if m.assocVersion == config.version then
        return m.assocMatcher
    end
    m.assocVersion = config.version
    local patt = {}
    for k, v in pairs(config.other.associations) do
        if m.eq(v, 'lua') then
            patt[#patt+1] = k
        end
    end
    m.assocMatcher = glob.glob(patt)
    if platform.OS == 'Windows' then
        m.assocMatcher:setOption 'ignoreCase'
    end
    return m.assocMatcher
end

--- 判断是否是Lua文件
---@param uri uri
---@return boolean
function m.isLua(uri)
    local ext = uri:match '%.([^%.%/%\\]+)$'
    if not ext then
        return false
    end
    if m.eq(ext, 'lua') then
        return true
    end
    local matcher = m.getAssoc()
    local path = furi.decode(uri)
    return matcher(path)
end

--- Does the uri look like a `Dynamic link library` ?
---@param uri uri
---@return boolean
function m.isDll(uri)
    local ext = uri:match '%.([^%.%/%\\]+)$'
    if not ext then
        return false
    end
    if platform.OS == 'Windows' then
        if m.eq(ext, 'dll') then
            return true
        end
    else
        if m.eq(ext, 'so') then
            return true
        end
    end
    return false
end

--- Save dll, makes opens and words, discard content
---@param uri uri
---@param content string
function m.saveDll(uri, content)
    if not content then
        return
    end
    local luri = getUriKey(uri)
    local file = {
        uri   = uri,
        opens = {},
        words = {},
    }
    for word in content:gmatch 'luaopen_([%w_]+)' do
        file.opens[#file.opens+1] = word:gsub('_', '.')
    end
    if #file.opens == 0 then
        return
    end
    local mark = {}
    for word in content:gmatch '(%a[%w_]+)\0' do
        if word:sub(1, 3) ~= 'lua' then
            if not mark[word] then
                mark[word] = true
                file.words[#file.words+1] = word
            end
        end
    end

    m.dllMap[luri] = file
end

---
---@param uri uri
---@return string[]|nil
function m.getDllOpens(uri)
    uri = getUriKey(uri)
    local file = m.dllMap[uri]
    if not file then
        return nil
    end
    return file.opens
end

---
---@param uri uri
---@return string[]|nil
function m.getDllWords(uri)
    uri = getUriKey(uri)
    local file = m.dllMap[uri]
    if not file then
        return nil
    end
    return file.words
end

--- 注册事件
function m.watch(callback)
    m.watchList[#m.watchList+1] = callback
end

function m.onWatch(ev, ...)
    for _, callback in ipairs(m.watchList) do
        callback(ev, ...)
    end
end

function m.flushCache()
    for uri, file in pairs(m.fileMap) do
        file.cacheActiveTime = math.huge
        m.linesMap[uri] = nil
        m.astMap[uri] = nil
        file.cache = {}
    end
end

function m.flushFileCache(uri)
    uri = getUriKey(uri)
    local file = m.fileMap[uri]
    if not file then
        return
    end
    file.cacheActiveTime = math.huge
    m.linesMap[uri] = nil
    m.astMap[uri] = nil
    file.cache = {}
end

local function init()
    --TODO 可以清空文件缓存，之后看要不要启用吧
    --timer.loop(10, function ()
    --    local list = {}
    --    for _, file in pairs(m.fileMap) do
    --        if timer.clock() - file.cacheActiveTime > 10.0 then
    --            file.cacheActiveTime = math.huge
    --            file.ast = nil
    --            file.cache = {}
    --            list[#list+1] = file.uri
    --        end
    --    end
    --    if #list > 0 then
    --        log.info('Flush file caches:', #list, '\n', table.concat(list, '\n'))
    --        collectgarbage()
    --    end
    --end)
end

xpcall(init, log.error)

return m
