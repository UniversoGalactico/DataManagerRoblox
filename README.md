**DataManager**  
Lightweight, production-ready data persistence for Roblox Luau.

---

### API

```lua
DataManager.Init(config: {StoreName: string, SessionTimeout: number?, AutosaveInterval: number?, Migrations: table?})
DataManager.LoadData(player: Player)
DataManager.SaveData(player: Player, isLeaving: boolean?)
DataManager.Get(player: Player, key: string): any
DataManager.Set(player: Player, key: string, value: any)
DataManager.TieneItem(player: Player, itemName: string): boolean
```

---

### Key Features

- **Serialization** – Supports `Vector3`, `CFrame`, `Color3`, `BrickColor`, `UDim2`, `Ray`, `EnumItem`. Preserves numeric array indices (`ipairs` works).
- **Session Locking** – `JobId`-based locking. Actively waits during teleports (no player kicks) with exponential backoff.
- **Atomic Saves** – Uses `UpdateAsync`. Respects external cloud changes (admin tools, cross-server events). Only overwrites managed keys (`Points`, `Inventory`, `Pets`, `PendingRewards`). Deleted items are removed from the cloud.
- **Concurrency** – Coroutine-based queue serializes `UpdateAsync` calls per key – no deadlocks.
- **Fault Tolerance** – Exponential backoff on API errors. Emergency backup (`pendingSaveBackup`) on failed saves. `BindToClose` saves all pending profiles.
- **Schema Evolution** – Additive migrations via `MIGRATIONS` map.

---

### Quick Start

```lua
local DataManager = require(script.Parent.DataManager)

DataManager.Init({ StoreName = "MyGame" })

Players.PlayerAdded:Connect(DataManager.LoadData)
Players.PlayerRemoving:Connect(function(p) DataManager.SaveData(p, true) end)

local coins = DataManager.Get(player, "Coins")
DataManager.Set(player, "Coins", coins + 100)

if DataManager.TieneItem(player, "Sword") then
    print("Has sword!")
end
```
