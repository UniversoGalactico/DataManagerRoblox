DataManager
Lightweight, session-locked data persistence module for Luau.

API Reference:

Lua


DataManager.Init(config: {StoreName: string, SessionTimeout: number?, ...})
DataManager.LoadData(player: Player)
DataManager.SaveData(player: Player, isLeaving: boolean?)
DataManager.Get(player: Player, key: string): any
DataManager.Set(player: Player, key: string, value: any)

Key Technical Specs:

Concurrency: Uses UpdateAsync with reconcile (merging) to prevent data loss.

Session Locking: JobID-based locking to prevent race conditions.

Schema Evolution: Supports additive migrations via migration maps.

Integrity: Validates Roblox-specific types and handles circular references in deepCopy.

Fault Tolerance: Built-in retry logic + automatic emergency save on BindToClose.

Quick Start:

Lua

DataManager.Init({ StoreName = "ProdStore" })

Players.PlayerAdded:Connect(DataManager.LoadData)
Players.PlayerRemoving:Connect(function(p) DataManager.SaveData(p, true) end)
