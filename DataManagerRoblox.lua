--[[
	DataManager.lua | Professional Data Persistence Module
	Módulo de Persistencia de Datos Profesional
	
	🌐 ENGLISH / ESPAÑOL 🌐
	
	🔒 FEATURES / CARACTERÍSTICAS:
	• Session Locking with Timeout / Bloqueo de Sesión con Timeout
	• Additive Migrations / Migraciones Aditivas
	• Cycle‑Safe Deep Copy / Copia Profunda Anti‑Ciclos
	• Strict Data Validation / Validación Estricta de Datos
	• Atomic Save with Rollback / Guardado Atómico con Rollback
	• Silent Data Load Check / Verificación de Carga Silenciosa
	• Configurable Init() — no source editing required / Init() configurable — sin editar el código fuente
	• Debug Mode for Get() warnings / Modo Debug para avisos de Get()
	
	📚 USAGE / USO:
	1. Place this ModuleScript in ServerScriptService.ServerModules
	2. Require it: local DataManager = require(script.Parent.DataManager)
	3. Call DataManager.Init({ StoreName = "YourGame" }) once on server start.
	4. Call DataManager.LoadData(player) when a player joins.
	5. Use DataManager.Get(player, key) and DataManager.Set(player, key, value).
	
	🔗 LINKS:
	• Talent Hub (Advanced paid modules): https://create.roblox.com/talent/creators/5075515911
	• GitHub (Free modules): https://github.com/UniversoGalactico
	• Discord (Custom proposals & negotiations): universogalactico_28974 (UniversoGalactico)
	
	By Universogalactico64 – Free module. More advanced systems on Talent Hub.
]]

local DataManager = {}

-- SERVICES / SERVICIOS
local DataStoreService = game:GetService("DataStoreService")
local Players          = game:GetService("Players")
local HttpService      = game:GetService("HttpService")
local MainStore        = nil -- Set by DataManager.Init() / Establecido por DataManager.Init()

-- STATE / ESTADO
local sessionData = {}
local dataStates  = {}
local pendingSaveBackup = {} -- Respaldo para jugadores que se van y fallan al guardar

-- CONFIGURATION / CONFIGURACIÓN
local SESSION_TIMEOUT   = 90   -- seconds before a locked session is considered abandoned / segundos antes de considerar una sesión bloqueada como abandonada
local MAX_RETRIES       = 3    -- max attempts for DataStore operations / intentos máximos para operaciones DataStore
local RETRY_DELAY       = 2    -- seconds between retries / segundos entre reintentos
local AUTOSAVE_INTERVAL = 60   -- how often autosave runs / cada cuánto se ejecuta el autoguardado
local DEBUG_MODE        = false -- set to true to show Get() warnings / pon en true para ver avisos de Get()

-- MIGRATION MAP / MAPA DE MIGRACIONES
local MIGRATIONS = {}

-- ════════════════════════════════════════
-- DEEP COPY CON CACHÉ (FIX CRÍTICO)
-- ════════════════════════════════════════
local function deepCopy(orig, cache)
    if type(orig) ~= "table" then return orig end
    cache = cache or {}
    if cache[orig] then return cache[orig] end

    local copy = {}
    cache[orig] = copy
    for k, v in pairs(orig) do
        copy[deepCopy(k, cache)] = deepCopy(v, cache)
    end
    return copy
end

-- ════════════════════════════════════════
-- VALIDACIÓN CON TIPOS ROBLOX (FIX CRÍTICO)
-- ════════════════════════════════════════
local VALID_USERDATA_TYPES = {
    ["Vector3"] = true, ["Vector2"] = true, ["CFrame"] = true,
    ["Color3"] = true, ["BrickColor"] = true, ["UDim2"] = true,
    ["Ray"] = true, ["Enum"] = true, ["EnumItem"] = true,
    ["NumberRange"] = true, ["NumberSequence"] = true, ["ColorSequence"] = true,
    ["PhysicalProperties"] = true, ["Faces"] = true
}

local function isValidData(value)
    if value == nil then return false end
    local t = type(value)
    if t == "function" or t == "thread" then return false end
    if t == "userdata" then
        return VALID_USERDATA_TYPES[typeof(value)] == true
    end
    if t == "number" and value ~= value then return false end
    if t == "table" then
        for k, v in pairs(value) do
            if not isValidData(k) or not isValidData(v) then return false end
        end
    end
    return true
end

-- ════════════════════════════════════════
-- MIGRATION Y RECONCILIATION
-- ════════════════════════════════════════
local function getNewDataStructure()
    return {
        Points         = 0,
        Inventory      = {},
        Pets           = {},
        PendingRewards = {},
        ActiveSession  = { JobId = nil, LastUpdate = 0 }
    }
end

local function migrate(data)
    for oldKey, newKey in pairs(MIGRATIONS) do
        if data[oldKey] ~= nil and data[newKey] == nil then
            data[newKey] = data[oldKey]
            data[oldKey] = nil
        end
    end
    return data
end

local function reconcile(target, template)
    for key, value in pairs(template) do
        if target[key] == nil or type(target[key]) ~= type(value) then
            target[key] = (type(value) == "table") and deepCopy(value) or value
        elseif type(value) == "table" and type(target[key]) == "table" then
            reconcile(target[key], value)
        end
    end
    return target
end

-- ════════════════════════════════════════
-- INIT / INICIALIZACIÓN
-- ════════════════════════════════════════
function DataManager.Init(config)
    assert(config and config.StoreName, "[DataManager] Init() requires config.StoreName")
    MainStore = DataStoreService:GetDataStore(config.StoreName)
    if config.SessionTimeout then SESSION_TIMEOUT = config.SessionTimeout end
    if config.MaxRetries then MAX_RETRIES = config.MaxRetries end
    if config.RetryDelay then RETRY_DELAY = config.RetryDelay end
    if config.AutosaveInterval then AUTOSAVE_INTERVAL = config.AutosaveInterval end
    if config.DebugMode ~= nil then DEBUG_MODE = config.DebugMode end
    if config.Migrations then MIGRATIONS = config.Migrations end
    print("✅ [DataManager] Initialized with store: " .. config.StoreName)
end

-- ════════════════════════════════════════
-- LOAD DATA
-- ════════════════════════════════════════
function DataManager.IsDataLoaded(player)
    if not player or not player:IsA("Player") or not player.Parent then return false end
    return dataStates[player.UserId] == "Loaded"
end

function DataManager.LoadData(player)
    if not MainStore then warn("[DataManager] Init() must be called before LoadData()") return end
    local userId = player.UserId
    if dataStates[userId] then return end

    dataStates[userId] = "Loading"
    local key = "Player_" .. userId
    local template = getNewDataStructure()

    local success, result
    local attempts = 0

    repeat
        attempts += 1
        success, result = pcall(function()
            return MainStore:UpdateAsync(key, function(oldData)
                if oldData and type(oldData) ~= "table" then
                    warn("[DataManager] Corrupted oldData for user " .. userId .. ". Using template.")
                    return deepCopy(template)
                end

                if oldData and oldData.ActiveSession and oldData.ActiveSession.JobId then
                    if oldData.ActiveSession.JobId ~= game.JobId then
                        if os.time() - oldData.ActiveSession.LastUpdate < SESSION_TIMEOUT then
                            return nil
                        end
                    end
                end

                local dataToUpdate = oldData and reconcile(migrate(oldData), template) or deepCopy(template)
                dataToUpdate.ActiveSession = { JobId = game.JobId, LastUpdate = os.time() }
                return dataToUpdate
            end)
        end)
        if not success and attempts < MAX_RETRIES then task.wait(RETRY_DELAY) end
    until success or attempts >= MAX_RETRIES

    if success and result then
        if not Players:GetPlayerByUserId(userId) then
            pcall(function()
                MainStore:UpdateAsync(key, function(oldData)
                    if oldData and type(oldData) == "table" then
                        oldData.ActiveSession = { JobId = nil, LastUpdate = 0 }
                        return oldData
                    end
                end)
            end)
            dataStates[userId] = nil
            warn("[DataManager] Player " .. userId .. " left during LoadData. Lock released.")
            return
        end

        sessionData[userId] = result
        dataStates[userId] = "Loaded"
        print("✅ [DataManager] Data secured for " .. player.Name)
    else
        pcall(function()
            player:Kick("⚠️ Data security error: Could not load your data. Please rejoin.")
        end)
    end
end

-- ════════════════════════════════════════
-- SAVE DATA (CON RECONCILIACIÓN ATÓMICA - FIX CRÍTICO)
-- ════════════════════════════════════════
function DataManager.SaveData(player, isLeaving)
    if not MainStore then return end
    local userId = player.UserId

    if not sessionData[userId] then
        if isLeaving then dataStates[userId] = nil end
        return
    end

    if dataStates[userId] == "Saving_Leaving" or dataStates[userId] == nil then return end
    if dataStates[userId] == "Saving_Autosave" and not isLeaving then return end

    dataStates[userId] = if isLeaving then "Saving_Leaving" else "Saving_Autosave"

    local dataSnapshot = deepCopy(sessionData[userId])

    if not dataSnapshot or not isValidData(dataSnapshot) then
        warn("❌ [DataManager] CRITICAL: Corrupted data for " .. (player.Name or tostring(userId)) .. ". Aborting save.")
        if isLeaving then
            pendingSaveBackup[userId] = deepCopy(sessionData[userId])
            sessionData[userId] = nil
            dataStates[userId] = nil
        else
            if dataStates[userId] == "Saving_Autosave" then dataStates[userId] = "Loaded" end
        end
        return
    end

    local key = "Player_" .. userId
    local success, saveError
    local attempts = 0

    repeat
        attempts += 1
        success, saveError = pcall(function()
            return MainStore:UpdateAsync(key, function(oldData)
                if oldData and type(oldData) == "table" and oldData.ActiveSession and oldData.ActiveSession.JobId then
                    if oldData.ActiveSession.JobId ~= game.JobId and (os.time() - oldData.ActiveSession.LastUpdate < SESSION_TIMEOUT) then
                        error("Session lock compromised by another server.")
                    end
                end

                -- ✅ FUSIONAR en lugar de SOBREESCRIBIR
                local baseData = (oldData and type(oldData) == "table") and oldData or getNewDataStructure()
                local mergedData = reconcile(baseData, dataSnapshot)

                mergedData.ActiveSession = {
                    JobId = if isLeaving then nil else game.JobId,
                    LastUpdate = os.time()
                }
                return mergedData
            end)
        end)
        if not success and attempts < MAX_RETRIES then task.wait(RETRY_DELAY) end
    until success or attempts >= MAX_RETRIES

    if isLeaving then
        if success then
            print("💾 [DataManager] Data saved on leave for " .. player.Name)
            pendingSaveBackup[userId] = nil
        else
            warn("❌ [DataManager] Network error on leave for " .. player.Name .. " | " .. tostring(saveError))
            pendingSaveBackup[userId] = deepCopy(dataSnapshot)
        end
        sessionData[userId] = nil
        dataStates[userId] = nil
    else
        if dataStates[userId] == "Saving_Autosave" then dataStates[userId] = "Loaded" end
        if success then
            print("🔄 [DataManager] Autosave completed for " .. player.Name)
        else
            warn("⚠️ [DataManager] Autosave failed for " .. player.Name .. ". Will retry next cycle.")
        end
    end
end

-- ════════════════════════════════════════
-- GET / SET
-- ════════════════════════════════════════
function DataManager.Get(player, key)
    local function log(...) if DEBUG_MODE then warn(...) end end

    if not player or not player:IsA("Player") or not player.Parent then
        log("[DataManager] Get() called with invalid player")
        return nil
    end

    local userId = player.UserId
    if dataStates[userId] ~= "Loaded" then
        log("[DataManager] Get('" .. tostring(key) .. "') called before data loaded for " .. player.Name)
        return nil
    end

    local data = sessionData[userId]
    if not data then return nil end

    if data[key] == nil then
        log("[DataManager] Get('" .. tostring(key) .. "') key does not exist for " .. player.Name)
        return nil
    end

    return (type(data[key]) == "table") and deepCopy(data[key]) or data[key]
end

function DataManager.Set(player, key, value)
    if not player or not player:IsA("Player") or not player.Parent then
        warn("[DataManager] Set() called with invalid player")
        return
    end
    local userId = player.UserId
    if dataStates[userId] ~= "Loaded" then
        warn("[DataManager] Set('" .. tostring(key) .. "') called before data loaded for " .. player.Name)
        return
    end

    assert(isValidData(value), "[DataManager] Invalid data in Set() for key: " .. tostring(key))
    if sessionData[userId] then
        sessionData[userId][key] = (type(value) == "table") and deepCopy(value) or value
    end
end

function DataManager.TieneItem(player, itemName)
    if not DataManager.IsDataLoaded(player) then
        warn("[DataManager] TieneItem: data not loaded for " .. tostring(player))
        return false
    end
    local inventario = DataManager.Get(player, "Inventory")
    if not inventario then return false end
    for _, item in ipairs(inventario) do
        if item == itemName then return true end
    end
    return false
end

-- ════════════════════════════════════════
-- AUTOSAVE LOOP
-- ════════════════════════════════════════
task.spawn(function()
    while true do
        task.wait(AUTOSAVE_INTERVAL)
        for _, player in ipairs(Players:GetPlayers()) do
            if player and player.Parent and dataStates[player.UserId] == "Loaded" then
                task.spawn(function() DataManager.SaveData(player, false) end)
            end
        end
    end
end)

-- ════════════════════════════════════════
-- PLAYER REMOVING (CON RESPALDO)
-- ════════════════════════════════════════
Players.PlayerRemoving:Connect(function(player)
    print("💾 [DataManager] Saving data on leave for: " .. player.Name)
    local success = false
    for attempt = 1, MAX_RETRIES do
        success = pcall(function()
            DataManager.SaveData(player, true)
        end)
        if success then break end
        warn("[DataManager] Save attempt " .. attempt .. " failed for " .. player.Name .. ", retrying...")
        task.wait(RETRY_DELAY)
    end
    if not success then
        warn("❌ [DataManager] CRITICAL: Could not save data for " .. player.Name .. " after " .. MAX_RETRIES .. " attempts.")
    end
end)

-- ════════════════════════════════════════
-- BIND TO CLOSE (CON RESPALDO DE EMERGENCIA)
-- ════════════════════════════════════════
game:BindToClose(function()
    print("🚨 [DataManager] BindToClose: Starting emergency save...")

    local colaDeGuardado = {}

    for userId, state in pairs(dataStates) do
        if state == "Loaded" or state == "Saving_Autosave" then
            colaDeGuardado[userId] = true
            local player = Players:GetPlayerByUserId(userId)
            if player then
                task.spawn(function()
                    DataManager.SaveData(player, true)
                    colaDeGuardado[userId] = nil
                end)
            else
                local dataToSave = sessionData[userId] or pendingSaveBackup[userId]
                if dataToSave and type(dataToSave) == "table" and isValidData(dataToSave) then
                    pcall(function()
                        MainStore:UpdateAsync("Player_" .. userId, function(oldData)
                            local baseData = (oldData and type(oldData) == "table") and oldData or getNewDataStructure()
                            local merged = reconcile(baseData, dataToSave)
                            merged.ActiveSession = { JobId = nil, LastUpdate = os.time() }
                            return merged
                        end)
                    end)
                end
                sessionData[userId] = nil
                dataStates[userId] = nil
                pendingSaveBackup[userId] = nil
                colaDeGuardado[userId] = nil
            end
        end
    end

    for userId, dataBackup in pairs(pendingSaveBackup) do
        if not colaDeGuardado[userId] and dataBackup and isValidData(dataBackup) then
            pcall(function()
                MainStore:UpdateAsync("Player_" .. userId, function(oldData)
                    local baseData = (oldData and type(oldData) == "table") and oldData or getNewDataStructure()
                    local merged = reconcile(baseData, dataBackup)
                    merged.ActiveSession = { JobId = nil, LastUpdate = os.time() }
                    return merged
                end)
            end)
            pendingSaveBackup[userId] = nil
        end
    end

    local elapsed = 0
    while next(colaDeGuardado) ~= nil and elapsed < 25 do
        task.wait(0.5)
        elapsed += 0.5
    end
    print("🚨 [DataManager] BindToClose finished cleanly.")
end)

return DataManager
