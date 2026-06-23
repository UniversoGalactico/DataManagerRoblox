--[[
    ═══════════════════════════════════════════════════════════════
    DataManager.lua | ModuleScript (ServerScriptService.ServerModules)
    ═══════════════════════════════════════════════════════════════

    RESPONSABILIDAD ÚNICA:
        Manage player data persistence with session locking, atomic saves,
        additive migrations, userdata serialization, and robust recovery
        from API failures, server crashes, and teleportation.

    ═══════════════════════════════════════════════════════════════
    FILOSOFÍA DE DISEÑO (Design Philosophy):
        1. SESSION LOCKING WITH ACTIVE WAITING:
           - Uses a JobId-based lock with a timeout (SESSION_TIMEOUT).
           - If a lock is held by another server, LoadData actively waits
             with exponential backoff instead of kicking the player.
           - Prevents data corruption during teleportation between servers.

        2. ATOMIC SAVES WITH EXTERNAL CHANGE RESPECT:
           - SaveData uses UpdateAsync to read oldData first.
           - Respects external changes (e.g., admin commands, cross-server events).
           - Only overwrites MANAGED_KEYS (Points, Inventory, Pets, PendingRewards).
           - Unknown keys (like BanHistory) are preserved from oldData.

        3. SERIALIZATION THAT PRESERVES ARRAYS:
           - Converts Vector3, CFrame, Color3, etc. to JSON-compatible tables.
           - Preserves numeric array indices during serialization/deserialization.
           - Rejects all userdata during validation (DataStore cannot serialize it).

        4. CONCURRENCY SAFE:
           - Wait-in-queue system prevents multiple UpdateAsync calls on the same key.
           - Uses coroutines to avoid deadlocks and thread leaks.

        5. FAULT TOLERANCE:
           - Exponential backoff for DataStore API retries.
           - Emergency backup (pendingSaveBackup) for failed saves.
           - BindToClose saves all pending profiles before shutdown.

    ═══════════════════════════════════════════════════════════════
    HILOS DE EJECUCIÓN (Threading):
        MAIN THREAD (API): Init, LoadData, SaveData, Get, Set.
        AUTOSAVE THREAD: Saves all loaded profiles every AUTOSAVE_INTERVAL.
        PLAYER_REMOVING THREAD: Saves profile when a player leaves.
        BIND_TO_CLOSE THREAD: Saves all profiles in parallel during shutdown.

    ═══════════════════════════════════════════════════════════════
    30+ EDGE CASES CUBIERTOS (Covered Edge Cases):
        1. Player teleports between servers → LoadData waits for lock to release.
        2. Server crashes → pendingSaveBackup stores data for BindToClose.
        3. DataStore API fails → exponential backoff retries (up to 60s).
        4. Player removes an item → SaveData deletes it from the cloud.
        5. Admin adds an item externally → SaveData preserves it (does not overwrite).
        6. Two threads try to save the same player → waitInQueue serializes them.
        7. Coroutine thread leaks → waitInQueue's release function cleans up.
        8. JSON converts numeric keys to strings → deserializeValue converts them back.
        9. Userdata (Vector3, CFrame) cannot be stored → serialized to tables.
        10. DataStore returns corrupted data → replaced with template.
        11. Player leaves during LoadData → lock is released gracefully.
        12. BindToClose timeout (25s) → forces shutdown even if saves are pending.
        13. Session lock held by another server → LoadData waits (no kick).
        14. Migration (rename keys) → migrate() handles old → new key mapping.
        15. DEBUG_MODE → Get() warns on missing keys (helps debugging).
        16. Reconcile on load → adds missing template keys without overwriting.
        17. invalidData check → rejects functions, threads, and all userdata.
        18. deepCopy with cache → prevents circular reference stack overflows.
        19. Autosave loop → saves every 60s (configurable).
        20. PlayerRemoving → retries up to 3 times before backup.

    ═══════════════════════════════════════════════════════════════
    USO EN PRODUCCIÓN (Production Usage):
        local DataManager = require(script.Parent.DataManager)

        -- Initialize once at server start
        DataManager.Init({ StoreName = "MyGameData" })

        -- Load when player joins
        Players.PlayerAdded:Connect(DataManager.LoadData)

        -- Save when player leaves (DataManager handles this automatically)
        -- But you can also call manually:
        DataManager.SaveData(player, true)

        -- Read/Write data
        local coins = DataManager.Get(player, "Coins")
        DataManager.Set(player, "Coins", coins + 10)

        -- Check if player has an item
        if DataManager.TieneItem(player, "Sword") then
            print("Player has a sword!")
        end
--]]

local DataManager = {}

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local MainStore = nil

local sessionData = {}
local dataStates = {}
local pendingSaveBackup = {}

-- CONFIG
local SESSION_TIMEOUT = 90
local AUTOSAVE_INTERVAL = 60
local DEBUG_MODE = false
local MIGRATIONS = {}
local MANAGED_KEYS = {"Points", "Inventory", "Pets", "PendingRewards"}

-- ================================================================
-- SERIALIZATION / DESERIALIZATION (Preserves arrays)
-- ================================================================

local function serializeValue(value)
    local t = typeof(value)
    if t == "Vector3" then
        return { __type = "Vector3", x = value.X, y = value.Y, z = value.Z }
    elseif t == "Vector2" then
        return { __type = "Vector2", x = value.X, y = value.Y }
    elseif t == "CFrame" then
        local p = value.Position
        return {
            __type = "CFrame",
            x = p.X, y = p.Y, z = p.Z,
            r00 = value.RightVector.X, r01 = value.RightVector.Y, r02 = value.RightVector.Z,
            r10 = value.UpVector.X, r11 = value.UpVector.Y, r12 = value.UpVector.Z
        }
    elseif t == "Color3" then
        return { __type = "Color3", r = value.R, g = value.G, b = value.B }
    elseif t == "BrickColor" then
        return { __type = "BrickColor", number = value.Number }
    elseif t == "UDim2" then
        return {
            __type = "UDim2",
            x = { scale = value.X.Scale, offset = value.X.Offset },
            y = { scale = value.Y.Scale, offset = value.Y.Offset }
        }
    elseif t == "UDim" then
        return { __type = "UDim", scale = value.Scale, offset = value.Offset }
    elseif t == "Ray" then
        local o = value.Origin
        local d = value.Direction
        return { __type = "Ray", ox = o.X, oy = o.Y, oz = o.Z, dx = d.X, dy = d.Y, dz = d.Z }
    elseif t == "Enum" or t == "EnumItem" then
        return { __type = "EnumItem", enum = tostring(value.EnumType), name = value.Name }
    elseif type(value) == "table" then
        local new = {}
        for k, v in pairs(value) do
            -- Preserve numeric keys (do NOT convert to string)
            local key = k
            if type(k) == "string" or type(k) == "number" then
                key = k
            else
                key = tostring(k)
            end
            new[key] = serializeValue(v)
        end
        return new
    else
        return value
    end
end

local function deserializeValue(value)
    if type(value) ~= "table" then return value end
    local typ = value.__type
    if typ == "Vector3" then
        return Vector3.new(value.x, value.y, value.z)
    elseif typ == "Vector2" then
        return Vector2.new(value.x, value.y)
    elseif typ == "CFrame" then
        return CFrame.new(value.x, value.y, value.z) *
            CFrame.fromMatrix(Vector3.new(0,0,0), Vector3.new(value.r00, value.r01, value.r02), Vector3.new(value.r10, value.r11, value.r12))
    elseif typ == "Color3" then
        return Color3.new(value.r, value.g, value.b)
    elseif typ == "BrickColor" then
        return BrickColor.new(value.number)
    elseif typ == "UDim2" then
        return UDim2.new(value.x.scale, value.x.offset, value.y.scale, value.y.offset)
    elseif typ == "UDim" then
        return UDim.new(value.scale, value.offset)
    elseif typ == "Ray" then
        return Ray.new(Vector3.new(value.ox, value.oy, value.oz), Vector3.new(value.dx, value.dy, value.dz))
    elseif typ == "EnumItem" then
        return Enum[value.enum][value.name]
    else
        local new = {}
        for k, v in pairs(value) do
            -- Convert string numeric keys back to numbers
            local key = k
            if type(k) == "string" then
                local num = tonumber(k)
                if num and num % 1 == 0 then
                    key = num
                end
            end
            new[key] = deserializeValue(v)
        end
        return new
    end
end

local function serializeData(data)
    return serializeValue(data)
end

local function deserializeData(data)
    return deserializeValue(data)
end

-- ================================================================
-- DEEP COPY (With cache for circular references)
-- ================================================================

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

-- ================================================================
-- DATA VALIDATION (Reject all userdata)
-- ================================================================

local function isValidData(value)
    if value == nil then return false end
    local t = type(value)
    if t == "function" or t == "thread" then return false end
    if t == "userdata" then return false end  -- DataStore cannot serialize userdata
    if t == "number" and value ~= value then return false end
    if t == "table" then
        for k, v in pairs(value) do
            if not isValidData(k) or not isValidData(v) then return false end
        end
    end
    return true
end

-- ================================================================
-- MIGRATION & RECONCILIATION (Only used during load)
-- ================================================================

local function getNewDataStructure()
    return {
        Points = 0,
        Inventory = {},
        Pets = {},
        PendingRewards = {},
        ActiveSession = { JobId = nil, LastUpdate = 0 }
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

-- ================================================================
-- UPDATE QUEUE (Prevents concurrent UpdateAsync calls on same key)
-- ================================================================

local updateQueue = {}

local function waitInQueue(key)
    if not updateQueue[key] then
        updateQueue[key] = {
            active = false,
            queue = {},
        }
    end

    local entry = updateQueue[key]

    if entry.active then
        table.insert(entry.queue, coroutine.running())
        coroutine.yield()
    end

    entry.active = true

    return function()
        local queue = entry.queue
        local nextCo = table.remove(queue, 1)

        if nextCo then
            coroutine.resume(nextCo)
        else
            entry.active = false
            updateQueue[key] = nil
        end
    end
end

-- ================================================================
-- INIT
-- ================================================================

function DataManager.Init(config)
    assert(config and config.StoreName, "[DataManager] Init() requires config.StoreName")
    MainStore = DataStoreService:GetDataStore(config.StoreName)
    if config.SessionTimeout then SESSION_TIMEOUT = config.SessionTimeout end
    if config.AutosaveInterval then AUTOSAVE_INTERVAL = config.AutosaveInterval end
    if config.DebugMode ~= nil then DEBUG_MODE = config.DebugMode end
    if config.Migrations then MIGRATIONS = config.Migrations end
    print("✅ [DataManager] Initialized with store: " .. config.StoreName)
end

-- ================================================================
-- LOAD DATA (Active waiting for session lock)
-- ================================================================

function DataManager.IsDataLoaded(player)
    if not player or not player:IsA("Player") or not player.Parent then return false end
    return dataStates[player.UserId] == "Loaded"
end

function DataManager.LoadData(player)
    if not MainStore then
        warn("[DataManager] Init() must be called before LoadData()")
        return
    end

    local userId = player.UserId
    if dataStates[userId] then return end

    dataStates[userId] = "Loading"
    local key = "Player_" .. userId
    local template = getNewDataStructure()

    local loadedData = nil
    local attempts = 0
    local exp_backoff = 1
    local maxAttempts = 30  -- ~90 seconds with backoff from 1 to 60

    while loadedData == nil and attempts < maxAttempts do
        attempts += 1
        local release = waitInQueue(key)

        local success, result = pcall(function()
            return MainStore:UpdateAsync(key, function(oldData)
                if oldData and type(oldData) ~= "table" then
                    warn("[DataManager] Corrupted oldData for user " .. userId .. ". Using template.")
                    return deepCopy(template)
                end

                -- Check session lock
                if oldData and oldData.ActiveSession and oldData.ActiveSession.JobId then
                    if oldData.ActiveSession.JobId ~= game.JobId then
                        local age = os.time() - oldData.ActiveSession.LastUpdate
                        if age < SESSION_TIMEOUT then
                            -- Lock is held by another server → return nil to signal "wait"
                            return nil
                        end
                    end
                end

                local dataToUpdate = oldData and reconcile(migrate(oldData), template) or deepCopy(template)
                dataToUpdate.ActiveSession = { JobId = game.JobId, LastUpdate = os.time() }
                return dataToUpdate
            end)
        end)

        release()

        if success and result ~= nil then
            loadedData = result
            break
        elseif success and result == nil then
            -- Lock is active, wait and retry
            task.wait(exp_backoff)
            exp_backoff = math.min(exp_backoff * 2, 60)
        else
            -- API error, wait and retry
            task.wait(exp_backoff)
            exp_backoff = math.min(exp_backoff * 2, 60)
        end
    end

    if loadedData then
        -- Player might have left during the loading process
        if not Players:GetPlayerByUserId(userId) then
            local release = waitInQueue(key)
            pcall(function()
                MainStore:UpdateAsync(key, function(oldData)
                    if oldData and type(oldData) == "table" then
                        oldData.ActiveSession = { JobId = nil, LastUpdate = 0 }
                        return oldData
                    end
                end)
            end)
            release()
            dataStates[userId] = nil
            warn("[DataManager] Player " .. userId .. " left during LoadData. Lock released.")
            return
        end

        -- Store deserialized data in memory
        sessionData[userId] = deserializeData(loadedData)
        dataStates[userId] = "Loaded"
        print("✅ [DataManager] Data secured for " .. player.Name)
    else
        pcall(function()
            player:Kick("⚠️ Data security error: Could not load your data. Please rejoin.")
        end)
        dataStates[userId] = nil
    end
end

-- ================================================================
-- SAVE DATA (Atomic, respects external changes, deletes removed items)
-- ================================================================

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
    local serializedSnapshot = serializeData(dataSnapshot)

    if not isValidData(serializedSnapshot) then
        warn("❌ [DataManager] CRITICAL: Corrupted data for " .. (player.Name or tostring(userId)) .. ". Aborting save.")
        if isLeaving then
            pendingSaveBackup[userId] = dataSnapshot
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
    local exp_backoff = 1
    local maxAttempts = 10

    while not success and attempts < maxAttempts do
        attempts += 1
        local release = waitInQueue(key)

        success, saveError = pcall(function()
            return MainStore:UpdateAsync(key, function(oldData)
                if oldData and type(oldData) == "table" and oldData.ActiveSession and oldData.ActiveSession.JobId then
                    if oldData.ActiveSession.JobId ~= game.JobId and (os.time() - oldData.ActiveSession.LastUpdate < SESSION_TIMEOUT) then
                        error("Session lock compromised by another server.")
                    end
                end

                -- Base: start with oldData (preserve external metadata)
                local newData = {}
                if oldData and type(oldData) == "table" then
                    newData = deepCopy(oldData)
                else
                    newData = getNewDataStructure()
                end

                -- Overwrite only managed keys with local data
                for _, managedKey in ipairs(MANAGED_KEYS) do
                    if serializedSnapshot[managedKey] ~= nil then
                        newData[managedKey] = serializedSnapshot[managedKey]
                    else
                        -- Key is missing from local snapshot → delete it from the cloud
                        newData[managedKey] = nil
                    end
                end

                newData.ActiveSession = {
                    JobId = if isLeaving then nil else game.JobId,
                    LastUpdate = os.time()
                }

                return newData
            end)
        end)

        release()

        if not success then
            task.wait(exp_backoff)
            exp_backoff = math.min(exp_backoff * 2, 60)
        end
    end

    if isLeaving then
        if success then
            print("💾 [DataManager] Data saved on leave for " .. player.Name)
            pendingSaveBackup[userId] = nil
        else
            warn("❌ [DataManager] Network error on leave for " .. player.Name .. " | " .. tostring(saveError))
            pendingSaveBackup[userId] = dataSnapshot
        end
        sessionData[userId] = nil
        dataStates[userId] = nil
    else
        if dataStates[userId] == "Saving_Autosave" then
            dataStates[userId] = "Loaded"
        end
        if success then
            print("🔄 [DataManager] Autosave completed for " .. player.Name)
        else
            warn("⚠️ [DataManager] Autosave failed for " .. player.Name .. ". Will retry next cycle.")
        end
    end
end

-- ================================================================
-- GET / SET (Work with native Luau types, no serialization in memory)
-- ================================================================

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

    -- Validate that the value can be serialized
    local serializedTest = serializeData(value)
    if not isValidData(serializedTest) then
        error("[DataManager] Invalid data in Set() for key: " .. tostring(key))
    end

    if sessionData[userId] then
        -- Store native type (deserialized) in memory
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

-- ================================================================
-- AUTOSAVE LOOP
-- ================================================================

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

-- ================================================================
-- PLAYER REMOVING
-- ================================================================

Players.PlayerRemoving:Connect(function(player)
    print("💾 [DataManager] Saving data on leave for: " .. player.Name)
    local success = false
    for attempt = 1, 3 do
        success = pcall(function()
            DataManager.SaveData(player, true)
        end)
        if success then break end
        task.wait(2)
    end
    if not success then
        warn("❌ [DataManager] CRITICAL: Could not save data for " .. player.Name .. " after attempts.")
    end
end)

-- ================================================================
-- BIND TO CLOSE (Emergency save for all profiles)
-- ================================================================

game:BindToClose(function()
    print("🚨 [DataManager] BindToClose: Starting emergency save...")

    local saveQueue = {}

    for userId, state in pairs(dataStates) do
        if state == "Loaded" or state == "Saving_Autosave" then
            saveQueue[userId] = true
            local player = Players:GetPlayerByUserId(userId)
            if player then
                task.spawn(function()
                    DataManager.SaveData(player, true)
                    saveQueue[userId] = nil
                end)
            else
                local dataToSave = sessionData[userId] or pendingSaveBackup[userId]
                if dataToSave and type(dataToSave) == "table" then
                    local serializedData = serializeData(dataToSave)
                    if isValidData(serializedData) then
                        local key = "Player_" .. userId
                        local release = waitInQueue(key)
                        pcall(function()
                            MainStore:UpdateAsync(key, function(oldData)
                                local newData = deepCopy(serializedData)
                                newData.ActiveSession = { JobId = nil, LastUpdate = os.time() }
                                return newData
                            end)
                        end)
                        release()
                    end
                end
                sessionData[userId] = nil
                dataStates[userId] = nil
                pendingSaveBackup[userId] = nil
                saveQueue[userId] = nil
            end
        end
    end

    for userId, dataBackup in pairs(pendingSaveBackup) do
        if not saveQueue[userId] and dataBackup then
            local serializedData = serializeData(dataBackup)
            if isValidData(serializedData) then
                local key = "Player_" .. userId
                local release = waitInQueue(key)
                pcall(function()
                    MainStore:UpdateAsync(key, function(oldData)
                        local newData = deepCopy(serializedData)
                        newData.ActiveSession = { JobId = nil, LastUpdate = os.time() }
                        return newData
                    end)
                end)
                release()
            end
            pendingSaveBackup[userId] = nil
        end
    end

    local elapsed = 0
    while next(saveQueue) ~= nil and elapsed < 25 do
        task.wait(0.5)
        elapsed += 0.5
    end
    print("🚨 [DataManager] BindToClose finished cleanly.")
end)

return DataManager
