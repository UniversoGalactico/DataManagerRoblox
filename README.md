# DataManager

**Lightweight, production-ready data persistence module for Roblox Luau.**  
Built for high-concurrency servers, teleportation, and fault tolerance.

---

## 📦 API Reference

```lua
-- Initialize the DataStore
DataManager.Init(config: {StoreName: string, SessionTimeout: number?, AutosaveInterval: number?, Migrations: table?})

-- Load data for a player
DataManager.LoadData(player: Player)

-- Save data manually (auto-save runs every 60 seconds)
DataManager.SaveData(player: Player, isLeaving: boolean?)

-- Read a value
DataManager.Get(player: Player, key: string): any

-- Write a value
DataManager.Set(player: Player, key: string, value: any)

-- Helper to check if a player has an item
DataManager.TieneItem(player: Player, itemName: string): boolean
