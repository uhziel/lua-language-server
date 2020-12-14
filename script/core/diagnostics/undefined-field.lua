local files   = require 'files'
local vm      = require 'vm'
local lang    = require 'language'
local config  = require 'config'
local guide   = require 'parser.guide'
local define  = require 'proto.define'

return function (uri, callback)
    local ast = files.getAst(uri)
    if not ast then
        return
    end

    local function getAllDocClassFromInfer(src)
        local infers = vm.getInfers(src, 0)

        if not infers then
            return nil
        end

        local mark = {}
        local function addTo(allDocClass, src)
            if not mark[src] then
                allDocClass[#allDocClass+1] = src
                mark[src] = true
            end
        end

        local allDocClass = {}
        for i = 1, #infers do
            local infer = infers[i]
            if infer.type ~= '_G' then
                local inferSource = infer.source
                if inferSource.type == 'doc.class' then
                    addTo(allDocClass, inferSource)
                elseif inferSource.type == 'doc.class.name' then
                    addTo(allDocClass, inferSource.parent)
                elseif inferSource.type == 'doc.type.name' then
                    local docTypes = vm.getDocTypes(inferSource[1])
                    for _, docType in ipairs(docTypes) do
                        if docType.type == 'doc.class.name' then
                            addTo(allDocClass, docType.parent)
                        end
                    end
                end
            end
        end

        return allDocClass
    end

    ---@param allDocClass table int
    local function getAllFieldsFromAllDocClass(allDocClass)
        local fields = {}
        local empty = true
        for _, docClass in ipairs(allDocClass) do
            local refs = vm.getFields(docClass)

            for _, ref in ipairs(refs) do
                if ref.type == 'getfield' or ref.type == 'getmethod' then
                    goto CONTINUE
                end
                local name = vm.getKeyName(ref)
                if not name or vm.getKeyType(ref) ~= 'string' then
                    goto CONTINUE
                end
                fields[name] = true
                empty = false
                ::CONTINUE::
            end
        end
       
        if empty then
            return nil
        else
            return fields
        end
    end

    local function checkUndefinedField(src)
        local fieldName = guide.getKeyName(src)

        local allDocClass = getAllDocClassFromInfer(src.node)
        if (not allDocClass) or (#allDocClass == 0) then
            return
        end

        local fields = getAllFieldsFromAllDocClass(allDocClass)

        -- 没找到任何 field，跳过检查
        if not fields then
            return
        end

        if not fields[fieldName] then
            local message = lang.script('DIAG_UNDEF_FIELD', fieldName)
            callback {
                start   = src.start,
                finish  = src.finish,
                message = message,
            }
        end
    end
    guide.eachSourceType(ast.ast, 'getfield', checkUndefinedField);
    guide.eachSourceType(ast.ast, 'getmethod', checkUndefinedField);
end
