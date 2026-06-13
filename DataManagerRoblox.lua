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
local MainStore        = nil -- Set by DataManager.Init() / Establecido por DataManager.Init()

-- STATE / ESTADO
local sessionData = {}
local dataStates  = {}

-- CONFIGURATION / CONFIGURACIÓN
local SESSION_TIMEOUT   = 90   -- seconds before a locked session is considered abandoned / segundos antes de considerar una sesión bloqueada como abandonada
local MAX_RETRIES       = 3    -- max attempts for DataStore operations / intentos máximos para operaciones DataStore
local RETRY_DELAY       = 2    -- seconds between retries / segundos entre reintentos
local AUTOSAVE_INTERVAL = 60   -- how often autosave runs / cada cuánto se ejecuta el autoguardado
local DEBUG_MODE        = false -- set to true to show Get() warnings / pon en true para ver avisos de Get()

-- MIGRATION MAP / MAPA DE MIGRACIONES
local MIGRATIONS = {}

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
-- DEFAULT DATA STRUCTURE / ESTRUCTURA DE DATOS POR DEFECTO
-- ════════════════════════════════════════
local function getNewDataStructure()
	return {
		Points         = 0,
		Inventory      = {},   -- Array of item names / Array de nombres de ítems
		Pets           = {},
		PendingRewards = {},
		ActiveSession  = { JobId = nil, LastUpdate = 0 }
	}
end

-- ════════════════════════════════════════
-- CYCLE‑SAFE DEEP COPY / COPIA PROFUNDA ANTI‑CICLOS
-- ════════════════════════════════════════
local function deepCopy(original)
	if type(original) ~= "table" then return nil end
	local seen = {}  -- Tracks visited tables to avoid infinite recursion / Rastrea tablas visitadas para evitar recursión infinita
	local function _deepCopy(orig)
		if type(orig) ~= "table" then return orig end
		if seen[orig] then
			-- Circular reference detected, return a simple marker / Referencia circular detectada, devuelve un marcador simple
			return { __cyclic = true }
		end
		seen[orig] = true
		local copy = {}
		for k, v in pairs(orig) do
			if type(v) == "table" then
				copy[_deepCopy(k)] = _deepCopy(v)
			else
				copy[_deepCopy(k)] = v
			end
		end
		return copy
	end
	return _deepCopy(original)
end

-- ════════════════════════════════════════
-- DATA VALIDATION / VALIDACIÓN DE DATOS
-- ════════════════════════════════════════
local function isValidData(value)
	if value == nil then return false end
	local t = type(value)
	if t == "function" or t == "userdata" or t == "thread" then return false end
	if typeof(value) == "Instance" then return false end
	if t == "number" and value ~= value then return false end

	if t == "table" then
		for k, v in pairs(value) do
			if not isValidData(k) or not isValidData(v) then return false end
		end
	end
	return true
end

-- ════════════════════════════════════════
-- MIGRATION / MIGRACIÓN
-- ════════════════════════════════════════
local function migrate(data)
	for oldKey, newKey in pairs(MIGRATIONS) do
		if data[oldKey] ~= nil and data[newKey] == nil then
			data[newKey] = data[oldKey]
			data[oldKey] = nil
		end
	end
	return data
end

-- ════════════════════════════════════════
-- ADDITIVE RECONCILIATION / RECONCILIACIÓN ADITIVA
-- ════════════════════════════════════════
local function reconcile(target, template)
	for key, value in pairs(template) do
		if target[key] == nil or type(target[key]) ~= type(value) then
			if type(value) == "table" then
				target[key] = deepCopy(value)
			else
				target[key] = value
			end
		elseif type(value) == "table" and type(target[key]) == "table" then
			reconcile(target[key], value)
		end
	end
	return target
end

-- ════════════════════════════════════════
-- SILENT DATA LOAD CHECK / VERIFICACIÓN SILENCIOSA DE CARGA
-- ════════════════════════════════════════
function DataManager.IsDataLoaded(player)
	if not player or not player:IsA("Player") or not player.Parent then
		return false
	end
	return dataStates[player.UserId] == "Loaded"
end

-- ════════════════════════════════════════
-- INITIAL LOAD / CARGA INICIAL
-- ════════════════════════════════════════
function DataManager.LoadData(player)
	if not MainStore then warn("[DataManager] Init() must be called before LoadData()") return end
	local userId = player.UserId
	if dataStates[userId] then return end

	dataStates[userId] = "Loading"
	local key      = "Player_" .. userId
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
				dataToUpdate.ActiveSession = {
					JobId      = game.JobId,
					LastUpdate = os.time()
				}
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
		dataStates[userId]  = "Loaded"
		print("✅ [DataManager] Data secured for " .. player.Name)
	else
		pcall(function()
			player:Kick("⚠️ Data security error: Could not load your data. Please rejoin.")
		end)
	end
end

-- ════════════════════════════════════════
-- SAVE / GUARDADO
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

	local key          = "Player_" .. userId
	local dataSnapshot = deepCopy(sessionData[userId])

	if not dataSnapshot or not isValidData(dataSnapshot) then
		warn("❌ [DataManager] CRITICAL: Corrupted data for " .. (player.Name or tostring(userId)) .. ". Aborting save.")
		if isLeaving then
			sessionData[userId] = nil
			dataStates[userId]  = nil
		else
			if dataStates[userId] == "Saving_Autosave" then
				dataStates[userId] = "Loaded"
			end
		end
		return
	end

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

				local dataToUpdate = deepCopy(dataSnapshot)
				dataToUpdate.ActiveSession = {
					JobId      = if isLeaving then nil else game.JobId,
					LastUpdate = os.time()
				}
				return dataToUpdate
			end)
		end)
		if not success and attempts < MAX_RETRIES then task.wait(RETRY_DELAY) end
	until success or attempts >= MAX_RETRIES

	if isLeaving then
		sessionData[userId] = nil
		dataStates[userId]  = nil
		if success then
			print("💾 [DataManager] Data saved on leave for " .. player.Name)
		else
			warn("❌ [DataManager] Network error on leave for " .. player.Name .. " | " .. tostring(saveError))
		end
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

-- ════════════════════════════════════════
-- GET / OBTENER
-- ════════════════════════════════════════
function DataManager.Get(player, key)
	-- Highly defensive getter. Warnings can be silenced by setting DEBUG_MODE = false.
	-- Getter altamente defensivo. Los avisos se pueden silenciar con DEBUG_MODE = false.
	local function log(...) if DEBUG_MODE then warn(...) end end

	local playerType = type(player)
	if playerType == "nil" then
		log("[DataManager] Get() called with player = nil")
		return nil
	elseif playerType == "number" then
		log("[DataManager] Get() received a number instead of a Player. userId: " .. tostring(player))
		return nil
	elseif playerType == "string" then
		log("[DataManager] Get() received a string instead of a Player. Value: " .. player)
		return nil
	elseif playerType == "table" then
		log("[DataManager] Get() received a table instead of a Player. Content: " .. tostring(player):sub(1,100))
		return nil
	elseif playerType ~= "userdata" then
		log("[DataManager] Get() received unexpected type: " .. playerType)
		return nil
	end

	if not player:IsA("Player") then
		log("[DataManager] Get() received an Instance that is not a Player. Class: " .. player.ClassName)
		return nil
	end
	if not player.Parent then
		log("[DataManager] Get() called on a Player that already left the game (" .. player.Name .. ")")
		return nil
	end

	local userId = player.UserId
	if dataStates[userId] ~= "Loaded" then
		log("[DataManager] Get('" .. tostring(key) .. "') called before data loaded for " .. player.Name)
		return nil
	end

	local data = sessionData[userId]
	if not data then
		log("[DataManager] Get('" .. tostring(key) .. "') no session data for " .. player.Name)
		return nil
	end

	if data[key] == nil then
		log("[DataManager] Get('" .. tostring(key) .. "') key does not exist for " .. player.Name
			.. ". Did you forget to add it to getNewDataStructure()?")
		return nil
	end

	if type(data[key]) == "table" then
		return deepCopy(data[key])
	end
	return data[key]
end

-- ════════════════════════════════════════
-- SET / ESTABLECER
-- ════════════════════════════════════════
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
		if type(value) == "table" then
			sessionData[userId][key] = deepCopy(value)
		else
			sessionData[userId][key] = value
		end
	end
end

-- ════════════════════════════════════════
-- HAS ITEM / TIENE ÍTEM
-- ════════════════════════════════════════
-- Assumes Inventory is an array of item names.
-- Asume que Inventory es un array de nombres de ítems.
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
-- AUTOSAVE LOOP / CICLO DE AUTOGUARDADO
-- ════════════════════════════════════════
task.spawn(function()
	while true do
		task.wait(AUTOSAVE_INTERVAL)
		for _, player in ipairs(Players:GetPlayers()) do
			if player and player.Parent and dataStates[player.UserId] == "Loaded" then
				task.spawn(function()
					DataManager.SaveData(player, false)
				end)
			end
		end
	end
end)

-- ════════════════════════════════════════
-- SAVE ON PLAYER LEAVING (WITH RETRIES) / GUARDADO AL SALIR (CON REINTENTOS)
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
	else
		-- Clean up local session after successful save
		sessionData[player.UserId] = nil
		dataStates[player.UserId]  = nil
	end
end)

-- ════════════════════════════════════════
-- BIND TO CLOSE (SERVER SHUTDOWN) / CIERRE DEL SERVIDOR
-- ════════════════════════════════════════
game:BindToClose(function()
	local colaDeGuardado = {}
	for userId, state in pairs(dataStates) do
		if state == "Loaded" or state == "Saving_Autosave" then
			colaDeGuardado[userId] = true
			local player = Players:GetPlayerByUserId(userId)
			if player then
				-- Player is still in game / El jugador aún está en el juego
				task.spawn(function()
					DataManager.SaveData(player, true)
					colaDeGuardado[userId] = nil
				end)
			else
				-- Player already left, save session data directly / El jugador ya se fue, guardar datos de sesión directamente
				task.spawn(function()
					local data = sessionData[userId]
					if data and type(data) == "table" then
						local dataSnapshot = deepCopy(data)
						if dataSnapshot and isValidData(dataSnapshot) then
							pcall(function()
								-- Usar siempre dataSnapshot como fuente más reciente, sin depender de oldData
								local dataToUpdate = deepCopy(dataSnapshot)
								dataToUpdate.ActiveSession = { JobId = nil, LastUpdate = os.time() }
								MainStore:SetAsync("Player_" .. userId, dataToUpdate)
							end)
						end
					end
					sessionData[userId] = nil
					dataStates[userId]  = nil
					colaDeGuardado[userId] = nil
				end)
			end
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
