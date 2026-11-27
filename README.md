# DataManager for Roblox

A small server-side Luau library for persistent profiles with session ownership. **3.0.0-rc.3** is a release candidate, not a production certification. MIT; no external dependencies.

## Install

Create a ModuleScript named DataManager in ServerScriptService and paste [DataManagerRoblox.lua](DataManagerRoblox.lua).

```lua
local DataManager = require(game.ServerScriptService.DataManager)
local store = DataManager.new({
    StoreName = "Profiles_v3", -- use a NEW store, see migration warning
    Template = {Coins = 0, Inventory = {}},
})

local profile, err = store:Load("Player_123")
if not profile then warn(err); return end
profile:Set("Coins", (profile:Get("Coins") or 0) + 10)
local saved, saveError = profile:Release()
if not saved then warn(saveError) end
```

[Player lifecycle example](examples/PlayerProfiles.server.lua) · [API and limits](docs/API.md) · [Tests and audit](docs/TESTING.md) · [Studio smoke test](tests/studio_smoke.server.lua) · [AI guide](AGENTS.md)

## API at a glance

| Function | Result |
| --- | --- |
| DataManager.new(config) | independent store manager |
| manager:Load(key) | profile or nil, error |
| profile:Get(key), Snapshot() | detached copy |
| profile:Set(key, value) | true or false, error; nil removes key |
| profile:Save() | true on confirmed write, otherwise false, error |
| profile:Release() | saves and releases ownership |
| profile:IsActive() | local usability, not a remote ownership check |
| manager:Close(seconds?) | true or false, error; bind to server shutdown |

Data must be plain serializable tables, strings, numbers or booleans. No Roblox Instances, metatables, cycles or sparse/mixed arrays. Autosave renews even idle profiles. Release requests freeze the handle even if a save is busy; maintenance retries pending releases. A locally expired handle also freezes.

## Read before deployment

- **Breaking change:** v3 uses a new record format and API. Do not point it at a live legacy store; unknown formats are rejected rather than overwritten. Use a separate store and an offline migration after old writers stop.
- Studio is not silently switched to a mock. Enable API access only in a separate test experience/store, or explicitly inject an adapter.
- No guarantee against service outages, abrupt server termination, concurrent external writers or data loss. A successful in-memory Set is not a durable write. Never grant irreversible rewards based solely on Set.
- Session expiry uses the stored owner's timeout and wall-clock timestamps with a 30-second grace. A stale owner cannot overwrite a different token through this module's atomic update path. Local IsActive is not a distributed ownership proof.
- Tests simulate DataStore callbacks and failures; they do not certify actual Roblox quotas or production performance.

MIT — [LICENSE](LICENSE).
