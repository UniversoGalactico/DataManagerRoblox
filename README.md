# DataManager – Professional Data Persistence Module
# Módulo de Persistencia de Datos Profesional

🌐 **English** | **Español**

---

## 🇬🇧 English

A free, production‑ready data persistence module for Roblox.  
It handles session locking, additive migrations, atomic saves with rollback, and much more.

**What it offers:**
- **Session Locking** – Prevents a player from being loaded on two servers at once.
- **Additive Migrations** – Old players never lose progress when you update your data structure.
- **Atomic Saves** – Every write is verified with a follow‑up read. If it fails, it rolls back.
- **Cycle‑Safe Deep Copy** – Copies tables without crashing on circular references.
- **Strict Data Validation** – Only safe values reach the DataStore.
- **Silent Debug Mode** – Warnings can be turned off in production.
- **Configurable Init()** – Set your store name, timeouts and retries without editing the source.

**How to use:**
1. Place the `ModuleScript` in `ServerScriptService.ServerModules`.
2. Require it: `local DataManager = require(script.Parent.DataManager)`
3. Call `DataManager.Init({ StoreName = "YourGame" })` once on server start.
4. Call `DataManager.LoadData(player)` when a player joins.
5. Use `DataManager.Get(player, key)` and `DataManager.Set(player, key, value)`.

**Links:**
- **Toolbox / Creator Store:** [Get the model](https://create.roblox.com/store/asset/113143891381960)
- **Talent Hub:** [More advanced modules](https://create.roblox.com/talent/creators/5075515911)
- **Discord:** universogalactico_28974 (UniversoGalactico)

---

## 🇪🇸 Español

Un módulo de persistencia de datos gratuito y listo para producción en Roblox.  
Incluye bloqueo de sesión, migraciones aditivas, guardado atómico con rollback y mucho más.

**Qué ofrece:**
- **Bloqueo de Sesión** – Evita que un jugador se cargue en dos servidores a la vez.
- **Migraciones Aditivas** – Los jugadores antiguos nunca pierden su progreso al actualizar la estructura de datos.
- **Guardado Atómico** – Cada escritura se verifica con una lectura posterior. Si falla, se revierte.
- **Copia Profunda Anti‑Ciclos** – Copia tablas sin romperse con referencias circulares.
- **Validación Estricta de Datos** – Solo valores seguros llegan al DataStore.
- **Modo Debug Silencioso** – Los avisos se pueden desactivar en producción.
- **Init() Configurable** – Define el nombre del DataStore, timeouts y reintentos sin editar el código fuente.

**Cómo usarlo:**
1. Coloca el `ModuleScript` en `ServerScriptService.ServerModules`.
2. Requiérelo: `local DataManager = require(script.Parent.DataManager)`
3. Llama a `DataManager.Init({ StoreName = "TuJuego" })` al iniciar el servidor.
4. Llama a `DataManager.LoadData(player)` cuando un jugador se una.
5. Usa `DataManager.Get(player, key)` y `DataManager.Set(player, key, value)`.

**Enlaces:**
- **Toolbox / Creator Store:** [Obtener el modelo](https://create.roblox.com/store/asset/113143891381960)
- **Talent Hub:** [Módulos avanzados de pago](https://create.roblox.com/talent/creators/5075515911)
- **Discord:** universogalactico_28974 (UniversoGalactico)

---

*Made with ❤️ by Universogalactico64*
