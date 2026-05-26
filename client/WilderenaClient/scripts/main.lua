--[[
    WilderenaClient — Client-side VFX & scoreboard (Event-Driven Architecture)
    Caps Lock = toggle scoreboard
    VFX triggered INLINE by MC_Event hook — ZERO polling loops during gameplay.
    Three hooks: MC_Event (instant VFX), MC_Timer (1s display), MC_Scoreboard (5s stats)
]]

local scoreboard_visible = false
local niagaraLib = nil
local _cached_niagara_sys = {}  -- [asset_name] = NiagaraSystem UObject (cached from pin phase, prevents GC)
local _cached_vent_class = nil  -- BP_AnimaVent_C class reference (cached from preload, prevents GC)

-- ============================================================================
-- WILDERENA SERVER GATE
-- All features stay DORMANT on offline / non-Wilderena servers. Activated
-- when any MC_Event/MC_Timer/MC_Scoreboard RPC fires (these originate ONLY
-- from the Wilderena server-side mod).
-- ============================================================================
local _wilderena_active = false
local function _activate_wilderena()
    if _wilderena_active then return end
    _wilderena_active = true
    print("[WilderenaClient] Wilderena server detected - features ENABLED\n")
end

-- ============================================================================
-- VFX CONFIG
-- ============================================================================
local FLAG_POSITIONS = {
    red  = {X = 19591, Y = 181199, Z = 244},
    blue = {X = 10178, Y = 190630, Z = 229},
}

local POWERUP_POSITIONS = {
    {X = 12840, Y = 183919, Z = 154},
    {X = 14853, Y = 185928, Z = -198},
    {X = 16865, Y = 187947, Z = 154},
}

-- Calibrated beam angles (single config for both teams — blue's values)
local BEAM_CONFIG = {
    red  = {roll = 94.25, pitch = 0.2, z_off = -220},
    blue = {roll = 94.25, pitch = 0.2, z_off = -220},
}

-- Powerup stack Z offsets (from calibration session)
local POWERUP_Z = {
    vent  = -820,   -- AnimaVent beam column
    orb   = -80,    -- Niagara orbs
    anima = -130,   -- Wild Anima crystal
}

-- VFX state tracking
local vfx_state = {
    red_beam = nil,
    blue_beam = nil,
    red_beam_time = 0,
    blue_beam_time = 0,
    red_torch = nil,
    blue_torch = nil,
    powerup_orbs = {},
    powerup_vents = {},
    powerup_anima = {},
}
local TELEPORT_DELTA = 3000  -- units — any position jump > this = teleport
local BEAM_RESPAWN_INTERVAL = 8  -- seconds, beam lasts ~10s
local BEAMS_ENABLED = false  -- disabled (caused lag)

-- ============================================================================
-- NIAGARA HELPERS
-- ============================================================================
local function get_niagara_lib()
    if not niagaraLib then
        pcall(function() niagaraLib = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary") end)
    end
    return niagaraLib
end

-- Fast spawn: NO LoadAsset fallback (prevents game thread stalls mid-gameplay)
-- Assets must be pre-loaded via preload_powerup_assets or already in memory
local function spawn_niagara(world, asset_folder, asset_name, pos, rot)
    -- Check cached reference first (from pin phase — bypasses StaticFindObject)
    local sys = _cached_niagara_sys[asset_name]
    if not sys or not sys:IsValid() then
        local full_path = asset_folder .. "/" .. asset_name .. "." .. asset_name
        pcall(function() sys = StaticFindObject(full_path) end)
    end
    if not sys or not sys:IsValid() then
        return nil  -- silent skip — no LoadAsset stall, no spam logs
    end
    local lib = get_niagara_lib()
    if not lib then return nil end
    return lib:SpawnSystemAtLocation(
        world, sys, pos,
        rot or {Pitch = 0, Yaw = 0, Roll = 0},
        {X = 1, Y = 1, Z = 1},
        true, true, 0, false
    )
end

-- Slow spawn: WITH LoadAsset fallback. Only use at preload time or rare one-shot events.
local function spawn_niagara_with_load(world, asset_folder, asset_name, pos, rot)
    local full_path = asset_folder .. "/" .. asset_name .. "." .. asset_name
    local load_path = asset_folder .. "/" .. asset_name
    -- Check cached reference first (from pin phase)
    local sys = _cached_niagara_sys[asset_name]
    if not sys or not sys:IsValid() then
        pcall(function() sys = StaticFindObject(full_path) end)
    end
    if not sys or not sys:IsValid() then
        pcall(function() LoadAsset(load_path) end)
        pcall(function() sys = StaticFindObject(full_path) end)
        -- Cache if found (for future spawns)
        if sys and sys:IsValid() then
            _cached_niagara_sys[asset_name] = sys
        end
    end
    if not sys or not sys:IsValid() then
        print(string.format("[VFX] FAIL Niagara not loaded: %s\n", full_path))
        return nil
    end
    local lib = get_niagara_lib()
    if not lib then return nil end
    return lib:SpawnSystemAtLocation(
        world, sys, pos,
        rot or {Pitch = 0, Yaw = 0, Roll = 0},
        {X = 1, Y = 1, Z = 1},
        true, true, 0, false
    )
end

-- ============================================================================
-- PRELOAD: forward-declared, body assigned AFTER ALL_ORB_TYPES is declared
-- ============================================================================
local preload_powerup_assets  -- forward declaration

local function despawn_niagara(comp)
    if comp then
        pcall(function() comp:Deactivate() end)
        pcall(function() comp:DestroyComponent() end)
    end
end

-- ============================================================================
-- VFX SPAWN/DESPAWN
-- ============================================================================
local function spawn_flag_beam(team)
    local player = FindFirstOf("BP_PlayerCharacter_C")
    if not player then return nil end
    local world = player:GetWorld()
    if not world then return nil end

    local pos = FLAG_POSITIONS[team]
    local ppos = player:K2_GetActorLocation()
    local cfg = BEAM_CONFIG[team]
    local spawn_pos = {X = pos.X, Y = pos.Y, Z = ppos.Z + cfg.z_off}
    print(string.format("[VFX] %s beam @ %.0f,%.0f,%.0f (R=%.2f P=%.2f)\n",
        team, spawn_pos.X, spawn_pos.Y, spawn_pos.Z, cfg.roll, cfg.pitch))
    return spawn_niagara(world,
        "/Game/Art/VFX/Library/Character/Dragons/Generic", "NS_VFX_Dragonfire_Laser",
        spawn_pos,
        {Pitch = cfg.pitch, Yaw = 0, Roll = cfg.roll})
end

local function spawn_flag_pickup_vfx(flag_pos)
    local player = FindFirstOf("BP_PlayerCharacter_C")
    if not player then return end
    local world = player:GetWorld()
    if not world then return end
    -- Fire cast at flag position
    spawn_niagara(world,
        "/Game/Art/VFX/Library/Combat/Magic/Fire", "NS_Magic_Fire_Cast",
        flag_pos, nil)
end

-- Orbs re-enabled: Astral + Air (Fire disabled per earlier preference)
local ALL_ORB_TYPES = {
    {folder = "/Game/Art/VFX/Library/Env/AnimaVent/Astral", asset = "NS_Anima_Loop_Astral"},
    {folder = "/Game/Art/VFX/Library/Env/AnimaVent/Air",    asset = "NS_Anima_Loop_Air"},
}

-- Assign preload body now that ALL_ORB_TYPES is in scope
preload_powerup_assets = function()
    -- BP_AnimaVent_C asset paths (try several candidates)
    local vent_paths = {
        "/Game/Gameplay/World/AnimaVent/BP_AnimaVent",
        "/Game/Gameplay/WorldElements/AnimaVent/BP_AnimaVent",
        "/Game/Gameplay/Environment/AnimaVent/BP_AnimaVent",
        "/Game/Gameplay/Anima/BP_AnimaVent",
        "/Game/Gameplay/AnimaVent/BP_AnimaVent",
    }
    for _, p in ipairs(vent_paths) do
        pcall(function() LoadAsset(p) end)
    end

    for _, orb in ipairs(ALL_ORB_TYPES) do
        pcall(function() LoadAsset(orb.folder .. "/" .. orb.asset) end)
    end

    local loaded = 0
    for _, orb in ipairs(ALL_ORB_TYPES) do
        local full = orb.folder .. "/" .. orb.asset .. "." .. orb.asset
        local s = nil
        pcall(function() s = StaticFindObject(full) end)
        if s then loaded = loaded + 1 end
    end
    print(string.format("[VFX] Preload: %d/%d orb assets loaded\n", loaded, #ALL_ORB_TYPES))

    local vent = FindFirstOf("BP_AnimaVent_C")
    if vent and vent:IsValid() then
        pcall(function() _cached_vent_class = vent:GetClass() end)
    end
    print(string.format("[VFX] Preload: BP_AnimaVent_C template = %s (cached class = %s)\n",
        vent and "OK" or "NOT FOUND", _cached_vent_class and "YES" or "NO"))
end

-- ============================================================================
-- ASSET PINNING: spawn hidden Niagara instances to create hard UObject
-- references that prevent garbage collection. Without this, LoadAsset/
-- StaticFindObject is unreliable — UE4 GC collects assets that have no
-- spawned component referencing them, regardless of Lua variables.
-- ============================================================================
local _asset_pins = {}

local function pin_niagara_assets()
    local player = FindFirstOf("BP_PlayerCharacter_C")
    if not player then return false end
    local world = player:GetWorld()
    if not world then return false end

    local pin_pos = {X = 0, Y = 0, Z = -99999}
    local pinned = 0
    for _, orb in ipairs(ALL_ORB_TYPES) do
        -- Check if existing pin is still valid (destroyed on level transition)
        local existing_valid = false
        if _asset_pins[orb.asset] then
            pcall(function() existing_valid = _asset_pins[orb.asset]:IsValid() end)
        end

        if not existing_valid then
            -- Clear stale references
            _asset_pins[orb.asset] = nil
            _cached_niagara_sys[orb.asset] = nil

            local full_path = orb.folder .. "/" .. orb.asset .. "." .. orb.asset
            pcall(function() LoadAsset(orb.folder .. "/" .. orb.asset) end)
            local sys = nil
            pcall(function() sys = StaticFindObject(full_path) end)
            if sys and sys:IsValid() then
                _cached_niagara_sys[orb.asset] = sys
                local lib = get_niagara_lib()
                if lib then
                    local comp = lib:SpawnSystemAtLocation(
                        world, sys, pin_pos,
                        {Pitch = 0, Yaw = 0, Roll = 0},
                        {X = 1, Y = 1, Z = 1},
                        true, true, 0, false)
                    if comp then
                        _asset_pins[orb.asset] = comp
                        pinned = pinned + 1
                    end
                end
            end
        else
            pinned = pinned + 1
        end
    end
    print(string.format("[VFX] Asset pins: %d/%d orb systems pinned (fresh)\n", pinned, #ALL_ORB_TYPES))
    return pinned == #ALL_ORB_TYPES
end

-- Config: all powerup layers re-enabled (lag was from early MC_Sync, not visuals)
local WILD_ANIMA_ENABLED = true
local VENT_ENABLED = true
local POWERUP_SPAWN_STAGGER_MS = 2000

-- Keep ALL orb assets alive by touching them (prevents GC between staggered spawns)
local function touch_all_orb_assets()
    for _, orb in ipairs(ALL_ORB_TYPES) do
        pcall(function() LoadAsset(orb.folder .. "/" .. orb.asset) end)
    end
end

-- Individual spawn helpers for staggered execution
-- Spawn a SINGLE orb type at a powerup position (uses LoadAsset fallback — safe because staggered)
local function spawn_single_orb(index, orb_type_idx)
    -- Reload ALL orb assets before each spawn to prevent GC from collecting
    -- the ones we haven't spawned yet during the 2s stagger gap
    touch_all_orb_assets()
    local player = FindFirstOf("BP_PlayerCharacter_C")
    if not player then return end
    local world = player:GetWorld()
    if not world then return end
    local orb = ALL_ORB_TYPES[orb_type_idx]
    if not orb then return end
    local pos = POWERUP_POSITIONS[index]
    local orb_pos = {X = pos.X, Y = pos.Y, Z = pos.Z + POWERUP_Z.orb}
    -- Use with_load variant: re-loads asset if GC'd between preload and spawn
    local comp = spawn_niagara_with_load(world, orb.folder, orb.asset, orb_pos, nil)
    if comp then
        if not vfx_state.powerup_orbs[index] then vfx_state.powerup_orbs[index] = {} end
        table.insert(vfx_state.powerup_orbs[index], comp)
        print(string.format("[VFX] Powerup %d: orb %s spawned\n", index, orb.asset))
    else
        print(string.format("[VFX] Powerup %d: orb %s FAILED to spawn\n", index, orb.asset))
    end
end

local function spawn_vent_layer(index)
    if not VENT_ENABLED then return end
    local player = FindFirstOf("BP_PlayerCharacter_C")
    if not player then print(string.format("[VFX] Powerup %d vent FAIL: no player\n", index)) return end
    local world = player:GetWorld()
    if not world then print(string.format("[VFX] Powerup %d vent FAIL: no world\n", index)) return end
    local pos = POWERUP_POSITIONS[index]

    -- If vent already exists (from prior spawn), un-hide + move back
    if vfx_state.powerup_vents[index] then
        pcall(function()
            local v = vfx_state.powerup_vents[index]
            if v and v:IsValid() then
                local vent_pos = {X = pos.X, Y = pos.Y, Z = pos.Z + POWERUP_Z.vent}
                pcall(function() v:SetActorHiddenInGame(false) end)
                v:K2_SetActorLocation(vent_pos, false, {}, true)
                print(string.format("[VFX] Powerup %d: vent un-hidden + restored\n", index))
            end
        end)
        return
    end

    -- Always try fresh FindFirstOf first (cached class may be stale after level transition)
    local cls = nil
    local template = FindFirstOf("BP_AnimaVent_C")
    if template and template:IsValid() then
        cls = template:GetClass()
        _cached_vent_class = cls
    else
        cls = _cached_vent_class
    end

    if not cls then
        print(string.format("[VFX] Powerup %d vent FAIL: BP_AnimaVent_C class not found\n", index))
        return
    end

    local ok, err = pcall(function()
        local vent_pos = {X = pos.X, Y = pos.Y, Z = pos.Z + POWERUP_Z.vent}
        local a = world:SpawnActor(cls, vent_pos, {})
        if a and a:IsValid() then
            pcall(function() a:SetActorEnableCollision(false) end)
            pcall(function() a:SetActorTickEnabled(false) end)
            pcall(function() a.bCanBeDamaged = false end)
            vfx_state.powerup_vents[index] = a
            print(string.format("[VFX] Powerup %d: vent spawned\n", index))
        else
            -- Cached class was stale — clear it and retry with fresh FindFirstOf
            _cached_vent_class = nil
            local retry_template = FindFirstOf("BP_AnimaVent_C")
            if retry_template and retry_template:IsValid() then
                local retry_cls = retry_template:GetClass()
                _cached_vent_class = retry_cls
                local a2 = world:SpawnActor(retry_cls, vent_pos, {})
                if a2 and a2:IsValid() then
                    pcall(function() a2:SetActorEnableCollision(false) end)
                    pcall(function() a2:SetActorTickEnabled(false) end)
                    pcall(function() a2.bCanBeDamaged = false end)
                    vfx_state.powerup_vents[index] = a2
                    print(string.format("[VFX] Powerup %d: vent spawned (retry)\n", index))
                else
                    print(string.format("[VFX] Powerup %d vent FAIL: SpawnActor returned nil (retry)\n", index))
                end
            else
                print(string.format("[VFX] Powerup %d vent FAIL: no template on retry\n", index))
            end
        end
    end)
    if not ok then print(string.format("[VFX] Powerup %d vent ERROR: %s\n", index, tostring(err))) end
end

local function spawn_anima_layer(index)
    if not WILD_ANIMA_ENABLED then return end
    -- Wild Anima is permanent — skip if already spawned
    if vfx_state.powerup_anima[index] then return end
    local player = FindFirstOf("BP_PlayerCharacter_C")
    if not player then return end
    local world = player:GetWorld()
    if not world then return end
    local pos = POWERUP_POSITIONS[index]
    pcall(function()
        local template = FindFirstOf("BP_BaseBuilding_Decoration_Material_Anima_Wild_C")
        if template and template:IsValid() then
            local anima_pos = {X = pos.X, Y = pos.Y, Z = pos.Z + POWERUP_Z.anima}
            local a = world:SpawnActor(template:GetClass(), anima_pos, {})
            if a and a:IsValid() then
                pcall(function() a:SetActorEnableCollision(false) end)
                pcall(function() a.bCanBeDamaged = false end)
                vfx_state.powerup_anima[index] = a
                print(string.format("[VFX] Powerup %d: anima spawned (permanent)\n", index))
            end
        end
    end)
end

-- PHASED staggered spawn: vents -> wild anima -> orbs, 2s between each spawn, 24s total
-- Phase 1 (Vents):      0s, 2s, 4s     (3 vents, all powerups)
-- Phase 2 (Wild Anima): 6s, 8s, 10s    (3 crystals, all powerups)
-- Phase 3 (Orbs):       12s, 14s, 16s, 18s, 20s, 22s  (6 orbs = 2 per powerup x 3)
local all_powerups_scheduled = false
local function schedule_all_powerup_stacks()
    -- DISABLED: server-side boot spawner now owns all powerup visuals (Wild anima + vent).
    -- Client-side Astral/Air orbs removed at user's request (duplicates with server Wild).
    if all_powerups_scheduled then return end
    all_powerups_scheduled = true
    print("[VFX] Powerup stack sequence DISABLED (server handles visuals)\n")
    do return end
    if not WILD_ANIMA_ENABLED and not VENT_ENABLED and #ALL_ORB_TYPES == 0 then
        print("[VFX] Powerup visuals all disabled -- skipping spawn schedule\n")
        return
    end
    print("[VFX] Scheduling full powerup stack sequence (24s)...\n")

    local stagger = POWERUP_SPAWN_STAGGER_MS  -- 2000ms

    -- Phase 1: Vents (2s, 4s, 6s)
    for i = 1, 3 do
        local delay = i * stagger
        local vi = i
        ExecuteWithDelay(delay, function()
            print(string.format("[VFX] Vent phase: powerup %d firing (delay=%dms)\n", vi, delay))
            ExecuteInGameThread(function()
                local ok, err = pcall(spawn_vent_layer, vi)
                if not ok then
                    print(string.format("[VFX] Vent spawn CRASH P%d: %s\n", vi, tostring(err)))
                end
            end)
        end)
    end

    -- Phase 2: Wild Anima (8s, 10s, 12s)
    for i = 1, 3 do
        local delay = (4 + (i - 1)) * stagger
        local ai = i
        ExecuteWithDelay(delay, function()
            print(string.format("[VFX] Anima phase: powerup %d firing (delay=%dms)\n", ai, delay))
            ExecuteInGameThread(function()
                local ok, err = pcall(spawn_anima_layer, ai)
                if not ok then
                    print(string.format("[VFX] Anima spawn CRASH P%d: %s\n", ai, tostring(err)))
                end
            end)
        end)
    end

    -- Phase 3: Orbs (14s, 16s, 18s)
    -- Spawn ALL orb types per position in the SAME tick (prevents GC between types)
    for i = 1, 3 do
        local delay = (7 + (i - 1)) * stagger
        local pup_i = i
        ExecuteWithDelay(delay, function()
            print(string.format("[VFX] Orb phase: powerup %d firing (delay=%dms)\n", pup_i, delay))
            ExecuteInGameThread(function()
                touch_all_orb_assets()
                for oi = 1, #ALL_ORB_TYPES do
                    local ok, err = pcall(spawn_single_orb, pup_i, oi)
                    if not ok then
                        print(string.format("[VFX] Orb spawn ERROR P%d orb %d: %s\n", pup_i, oi, tostring(err)))
                    end
                end
            end)
        end)
    end
end

local function reset_powerup_spawn_scheduled()
    all_powerups_scheduled = false
end

-- New behavior: Wild Anima is PERMANENT (always visible).
-- Orbs + AnimaVent cycle on pickup (disappear on cooldown, respawn when active).
local function despawn_powerup_pickup(index)
    print(string.format("[VFX] despawn_powerup_pickup(%d) called\n", index))
    -- Orbs: destroy Niagara components
    local orbs = vfx_state.powerup_orbs[index]
    if type(orbs) == "table" then
        for _, comp in ipairs(orbs) do despawn_niagara(comp) end
    elseif orbs then
        despawn_niagara(orbs)
    end
    vfx_state.powerup_orbs[index] = nil

    -- AnimaVent: hide + move (Niagara components may use world-space so move alone isn't enough)
    if vfx_state.powerup_vents[index] then
        local ok, err = pcall(function()
            local v = vfx_state.powerup_vents[index]
            if v and v:IsValid() then
                pcall(function() v:SetActorHiddenInGame(true) end)
                pcall(function() v:K2_SetActorLocation({X = 0, Y = 0, Z = -99999}, false, {}, true) end)
                print(string.format("[VFX] Powerup %d vent hidden + moved\n", index))
            else
                print(string.format("[VFX] Powerup %d vent not valid\n", index))
            end
        end)
        if not ok then print(string.format("[VFX] Powerup %d vent despawn ERROR: %s\n", index, tostring(err))) end
    else
        print(string.format("[VFX] Powerup %d no vent ref to despawn\n", index))
    end

    -- Wild Anima: LEAVE AS-IS (permanent marker, never touched)
end

-- Full cleanup (match end — destroy everything including vents)
local function despawn_powerup_all(index)
    despawn_powerup_pickup(index)
    if vfx_state.powerup_vents[index] then
        pcall(function()
            if vfx_state.powerup_vents[index]:IsValid() then
                vfx_state.powerup_vents[index]:K2_DestroyActor()
            end
        end)
        vfx_state.powerup_vents[index] = nil
    end
end

-- Find the nearest player to a world position (within max_dist)
local function find_nearest_player(world_pos, max_dist)
    local players = FindAllOf("BP_PlayerCharacter_C")
    if not players then return nil, nil end
    local best = nil
    local best_dist = max_dist or 9e9
    local best_pos = nil
    for _, p in pairs(players) do
        pcall(function()
            if p and p:IsValid() then
                local ppos = p:K2_GetActorLocation()
                if ppos then
                    local dx = ppos.X - world_pos.X
                    local dy = ppos.Y - world_pos.Y
                    local dz = ppos.Z - world_pos.Z
                    local d = math.sqrt(dx*dx + dy*dy + dz*dz)
                    if d < best_dist then
                        best_dist = d
                        best = p
                        best_pos = ppos
                    end
                end
            end
        end)
    end
    return best, best_pos
end

-- Spawn VFX on a player's world position
local function spawn_vfx_at_player(player, folder, asset, z_offset)
    if not player or not player:IsValid() then return end
    local world = player:GetWorld()
    if not world then return end
    local pos = player:K2_GetActorLocation()
    if not pos then return end
    local spawn_pos = {X = pos.X, Y = pos.Y, Z = pos.Z + (z_offset or 0)}
    spawn_niagara(world, folder, asset, spawn_pos, nil)
end

-- Powerup pickup: VinesSpawn at powerup position
local function spawn_powerup_pickup_vfx(index)
    local pos = POWERUP_POSITIONS[index]
    local player = FindFirstOf("BP_PlayerCharacter_C")
    if not player then return end
    local world = player:GetWorld()
    if not world then return end
    -- Use with_load variant in case asset was GC'd
    local comp = spawn_niagara_with_load(world,
        "/Game/Art/VFX/Library/Character/Imaru/BossFight/SpectralVines", "NS_VFX_VinesSpawn",
        {X = pos.X, Y = pos.Y, Z = pos.Z}, nil)
    print(string.format("[VFX] Powerup %d pickup VinesSpawn: %s\n", index, comp and "OK" or "FAIL"))
end

-- Flag capture VFX (catalog #5 + #8):
-- Windstep burst + dissolve out -> 1s -> dissolve back in (BP material dissolve)
local function spawn_flag_capture_on_carrier(home_team)
    local home_pos = FLAG_POSITIONS[home_team]
    local nearest = find_nearest_player(home_pos, 800)
    if nearest then
        -- Windstep burst (catalog #8)
        spawn_vfx_at_player(nearest,
            "/Game/Art/VFX/Library/Spells/Windstep", "NS_Windstep_Launch", 0)
        -- Dissolve IN only (dissolve out makes player invisible)
        pcall(function() nearest:PlayRespawnVFX() end)
    end
end

-- Spawn standing torch at flag position (colored by team)
local function spawn_flag_torch(team)
    local player = FindFirstOf("BP_PlayerCharacter_C")
    if not player then return nil end
    local world = player:GetWorld()
    if not world then return nil end

    local pos = FLAG_POSITIONS[team]
    local color = (team == "red") and "Red" or "Blue"
    local torch_pos = {X = pos.X, Y = pos.Y, Z = pos.Z - 130}

    local actor = nil
    pcall(function()
        local template = FindFirstOf("BP_BaseBuilding_TorchStanding_" .. color .. "_C")
        if not template then template = FindFirstOf("BP_BaseBuilding_TorchStanding_C") end
        if template and template:IsValid() then
            local a = world:SpawnActor(template:GetClass(), torch_pos, {})
            if a and a:IsValid() then
                pcall(function() a:SetActorEnableCollision(false) end)
                pcall(function() a.bCanBeDamaged = false end)
                actor = a
            end
        end
    end)
    if actor then
        print(string.format("[VFX] %s torch spawned at flag\n", color))
    end
    return actor
end

local function despawn_flag_torch(team)
    local key = team .. "_torch"
    if vfx_state[key] then
        pcall(function()
            if vfx_state[key]:IsValid() then
                vfx_state[key]:K2_DestroyActor()
            end
        end)
        vfx_state[key] = nil
    end
end

-- ============================================================================
-- VFX cleanup helper
-- ============================================================================
local function cleanup_all_vfx()
    despawn_niagara(vfx_state.red_beam)
    despawn_niagara(vfx_state.blue_beam)
    despawn_flag_torch("red")
    despawn_flag_torch("blue")
    for i = 1, 3 do
        despawn_powerup_all(i)  -- full cleanup including vents
    end
    reset_powerup_spawn_scheduled()
    vfx_state.red_beam = nil
    vfx_state.blue_beam = nil
    vfx_state.powerup_orbs = {}
    vfx_state.powerup_vents = {}
    vfx_state.powerup_anima = {}
end

-- ============================================================================
-- GAME STATE — populated ONLY by hooks, never by polling
-- ============================================================================
local game_state = {
    timer = "0:00",
    phase = "idle",           -- idle/team_select/class_select/preparation/active/ended
    red_flag = "base",        -- base/carried
    blue_flag = "base",
    powerups = {true, true, true},  -- active state per powerup
    red_torches = 0,
    blue_torches = 0,
    players = {},             -- [slot] = {name, class, kills, deaths, flags}
    winner = nil,
    builder_allowed = false,  -- shipped modpack: building BLOCKED by default; F9 (or admin "builder|enable") re-allows for dungeon authoring
}

-- ============================================================================
-- PLAYER REFERENCE CACHE — avoids FindAllOf in hot paths
-- ============================================================================
local player_cache = {}           -- [name] = player_ref
local player_cache_valid = false

local function refresh_player_cache()
    player_cache = {}
    local all = FindAllOf("BP_PlayerCharacter_C")
    if not all then return end
    for _, p in pairs(all) do
        pcall(function()
            if p and p:IsValid() then
                local ctrl = p:GetInstigatorController()
                if ctrl and ctrl:IsValid() then
                    local name = ctrl.PlayerState:GetPlayerName():ToString()
                    if name and name ~= "" then
                        player_cache[name] = p
                    end
                end
            end
        end)
    end
    player_cache_valid = true
end

local function get_player(name)
    if not player_cache_valid then refresh_player_cache() end
    local p = player_cache[name]
    if p then
        local valid = false
        pcall(function() valid = p:IsValid() end)
        if valid then return p end
    end
    -- Cache miss — refresh once
    refresh_player_cache()
    return player_cache[name]
end

-- ============================================================================
-- schedule_single_powerup_stack — staggered respawn for ONE powerup
-- ============================================================================
local function schedule_single_powerup_stack(index)
    -- DISABLED: server-side boot spawner owns powerup visuals. This client-side
    -- respawn schedule was re-spawning vent+anima+orbs duplicate to the server,
    -- causing two visible sets (Wild anima + Astral/Air orbs on top) after
    -- powerup respawn. Server's Powerups.spawn_visual handles respawn cleanly.
    print(string.format("[VFX] schedule_single_powerup_stack(%d) DISABLED (server owns visuals)\n", index))
end

-- ============================================================================
-- MC_EVENT HOOK — fires VFX INLINE when game events happen
-- Hook path: /Game/Mods/CTFScoreboard/ModActor.ModActor_C:MC_Event
-- ============================================================================
local mc_event_registered = false

local function register_mc_event_hook()
    if mc_event_registered then return true end
    local ma = FindFirstOf("ModActor_C")
    if not ma or not ma:IsValid() then return false end

    local ok = pcall(function()
        RegisterHook("/Game/Mods/CTFScoreboard/ModActor.ModActor_C:MC_Event", function(self, event_param)
            _activate_wilderena()
            pcall(function()
                local raw = nil
                pcall(function() raw = event_param:get():ToString() end)
                if not raw or raw == "" then return end

                local parts = {}
                for p in (raw .. "|"):gmatch("([^|]*)|") do
                    table.insert(parts, p)
                end
                local etype = parts[1] or ""

                ExecuteInGameThread(function()
                    pcall(function()
                        -- ======================
                        -- FLAG EVENTS
                        -- ======================
                        if etype == "flag" then
                            local action = parts[2]    -- pickup/capture/return
                            local flag_team = parts[3] -- red/blue

                            if action == "pickup" then
                                -- Despawn torch, fire pickup VFX
                                despawn_flag_torch(flag_team)
                                spawn_flag_pickup_vfx(FLAG_POSITIONS[flag_team])
                                if flag_team == "red" then
                                    game_state.red_flag = "carried"
                                else
                                    game_state.blue_flag = "carried"
                                end

                            elseif action == "capture" then
                                local carrier_team = parts[4]
                                local carrier_name = parts[5]
                                -- Windstep on carrier
                                local carrier = get_player(carrier_name)
                                if carrier then
                                    spawn_vfx_at_player(carrier,
                                        "/Game/Art/VFX/Library/Spells/Windstep", "NS_Windstep_Launch", 0)
                                    pcall(function() carrier:PlayRespawnVFX() end)
                                end
                                -- Respawn torch at flag
                                if flag_team == "red" then
                                    game_state.red_flag = "base"
                                    vfx_state.red_torch = spawn_flag_torch("red")
                                else
                                    game_state.blue_flag = "base"
                                    vfx_state.blue_torch = spawn_flag_torch("blue")
                                end

                            elseif action == "return" then
                                if flag_team == "red" then
                                    game_state.red_flag = "base"
                                    vfx_state.red_torch = spawn_flag_torch("red")
                                else
                                    game_state.blue_flag = "base"
                                    vfx_state.blue_torch = spawn_flag_torch("blue")
                                end
                            end

                        -- ======================
                        -- KILL EVENTS
                        -- ======================
                        elseif etype == "kill" then
                            local killer_name = parts[2]
                            local victim_name = parts[3]
                            -- SkillLevelUp on killer
                            local killer = get_player(killer_name)
                            if killer then
                                spawn_vfx_at_player(killer,
                                    "/Game/Art/VFX/Library/Character", "NS_SkillLevelUp_v02", 50)
                            end
                            -- Death dissolve on victim (backup — OnPlayerDeath hook also handles this)

                        -- ======================
                        -- POWERUP EVENTS
                        -- ======================
                        elseif etype == "powerup" then
                            local action = parts[2]
                            local index = tonumber(parts[3])
                            if action == "pickup" and index then
                                game_state.powerups[index] = false
                                despawn_powerup_pickup(index)
                                spawn_powerup_pickup_vfx(index)
                            elseif action == "respawn" and index then
                                game_state.powerups[index] = true
                                -- Stagger single powerup stack spawn
                                schedule_single_powerup_stack(index)
                            end

                        -- ======================
                        -- PHASE EVENTS
                        -- ======================
                        elseif etype == "phase" then
                            local new_phase = parts[2]
                            local old_phase = game_state.phase
                            game_state.phase = new_phase

                            if new_phase == "team_select" then
                                -- New match starting: hide lingering scoreboard from prior match
                                pcall(function()
                                    local mod_actor = FindFirstOf("ModActor_C")
                                    if mod_actor and mod_actor:IsValid() then
                                        local widget = mod_actor.ScoreboardWidget
                                        if widget and widget:IsValid() and widget.StatsPanel then
                                            scoreboard_visible = false
                                            widget.StatsPanel:SetVisibility(2)
                                            print("[WilderenaClient] Scoreboard hidden on new match start\n")
                                        end
                                    end
                                end)

                            elseif new_phase == "class_select" then
                                -- Pin assets + start powerup stacks during class selection
                                ExecuteInGameThread(function()
                                    pcall(function()
                                        preload_powerup_assets()
                                        pin_niagara_assets()
                                    end)
                                end)
                                -- Spawn powerup stacks 10s into class select (matches server Powerups.setup timing)
                                ExecuteWithDelay(10000, function()
                                    ExecuteInGameThread(function()
                                        pcall(function()
                                            preload_powerup_assets()
                                            pin_niagara_assets()
                                            reset_powerup_spawn_scheduled()
                                            schedule_all_powerup_stacks()
                                        end)
                                    end)
                                end)

                            elseif new_phase == "preparation" then
                                -- Pin assets again (insurance)
                                ExecuteInGameThread(function()
                                    pcall(function()
                                        preload_powerup_assets()
                                        pin_niagara_assets()
                                    end)
                                end)

                            elseif new_phase == "active" then
                                -- Match starting: spawn flag torches
                                vfx_state.red_torch = spawn_flag_torch("red")
                                vfx_state.blue_torch = spawn_flag_torch("blue")
                                -- Powerup stacks already spawned during class_select
                                -- If missed (late join), spawn now
                                if not all_powerups_scheduled then
                                    reset_powerup_spawn_scheduled()
                                    schedule_all_powerup_stacks()
                                end

                            elseif new_phase == "ended" then
                                game_state.winner = parts[3]
                                cleanup_all_vfx()
                                -- Auto-show scoreboard so players see final result without Caps Lock.
                                pcall(function()
                                    local mod_actor = FindFirstOf("ModActor_C")
                                    if mod_actor and mod_actor:IsValid() then
                                        local widget = mod_actor.ScoreboardWidget
                                        if widget and widget:IsValid() and widget.StatsPanel then
                                            scoreboard_visible = true
                                            widget.StatsPanel:SetVisibility(0)
                                            print("[WilderenaClient] Scoreboard auto-shown on match end\n")
                                        end
                                    end
                                end)

                            elseif new_phase == "idle" then
                                cleanup_all_vfx()
                                -- Auto-hide scoreboard when match ends its wind-down
                                pcall(function()
                                    local mod_actor = FindFirstOf("ModActor_C")
                                    if mod_actor and mod_actor:IsValid() then
                                        local widget = mod_actor.ScoreboardWidget
                                        if widget and widget:IsValid() and widget.StatsPanel then
                                            scoreboard_visible = false
                                            widget.StatsPanel:SetVisibility(2)
                                            print("[WilderenaClient] Scoreboard auto-hidden on idle\n")
                                        end
                                    end
                                end)
                            end

                        -- ======================
                        -- CLASS CHANGE EVENTS
                        -- ======================
                        elseif etype == "class" then
                            local player_name = parts[2]
                            local class_display = parts[3]
                            local p = get_player(player_name)
                            if p and p:IsValid() then
                                pcall(function() p:DissolveTeleport() end)
                            end

                        -- ======================
                        -- BUFF EVENTS (powerup applied)
                        -- ======================
                        elseif etype == "buff" then
                            local player_name = parts[2]
                            local p = get_player(player_name)
                            if p then
                                spawn_vfx_at_player(p,
                                    "/Game/Art/VFX/Library/Character/Imaru/BossFight/SpectralVines",
                                    "NS_VFX_VinesSpawn", 0)
                            end

                        elseif etype == "builder" then
                            local action = parts[2] -- enable/disable
                            if action == "enable" then
                                game_state.builder_allowed = true
                                print("[WilderenaClient] Builder ENABLED by admin\n")
                            else
                                game_state.builder_allowed = false
                                print("[WilderenaClient] Builder DISABLED by admin\n")
                            end

                        elseif etype == "camsnap" then
                            -- Server asks us to snap the LOCAL player's camera to a yaw.
                            -- Must be client-side: the client owns its control rotation,
                            -- so a server SetControlRotation gets overridden. Broadcast to
                            -- all clients; we filter to our own pawn by PlayerId.
                            local target_pid = tonumber(parts[2])
                            local snap_yaw = tonumber(parts[3])
                            if target_pid and snap_yaw then
                                ExecuteInGameThread(function()
                                    pcall(function()
                                        local pcs = FindAllOf("BP_PlayerCharacter_C")
                                        if not pcs then return end
                                        for _, pc in pairs(pcs) do
                                            pcall(function()
                                                if not pc or not pc:IsValid() then return end
                                                local is_local = false
                                                local called = pcall(function() is_local = pc:IsLocallyControlled() end)
                                                if called and not is_local then return end
                                                local c = pc:GetInstigatorController() or pc:GetController()
                                                if not c or not c:IsValid() then return end
                                                local mypid = nil
                                                pcall(function() mypid = c.PlayerState.PlayerId end)
                                                if mypid ~= target_pid then return end
                                                c:SetControlRotation({Pitch = 0, Yaw = snap_yaw, Roll = 0})
                                                print(string.format("[WilderenaClient] camsnap -> yaw=%d\n", snap_yaw))
                                            end)
                                        end
                                    end)
                                end)
                            end
                        end
                    end)
                end)
            end)
        end)
    end)

    if ok then
        mc_event_registered = true
        print("[WilderenaClient] MC_Event hook registered\n")
        return true
    end
    return false
end

-- ============================================================================
-- MC_TIMER HOOK — updates game_state.timer only
-- Hook path: /Game/Mods/CTFScoreboard/ModActor.ModActor_C:MC_Timer
-- ============================================================================
local mc_timer_registered = false

local function register_mc_timer_hook()
    if mc_timer_registered then return true end
    local ma = FindFirstOf("ModActor_C")
    if not ma or not ma:IsValid() then return false end

    local ok = pcall(function()
        RegisterHook("/Game/Mods/CTFScoreboard/ModActor.ModActor_C:MC_Timer", function(self, timer_param)
            _activate_wilderena()
            pcall(function()
                local t = nil
                pcall(function() t = timer_param:get():ToString() end)
                if t then game_state.timer = t end
            end)
        end)
    end)

    if ok then
        mc_timer_registered = true
        print("[WilderenaClient] MC_Timer hook registered\n")
        return true
    end
    return false
end

-- ============================================================================
-- MC_SCOREBOARD HOOK — updates game_state with player stats, flag/powerup state
-- Hook path: /Game/Mods/CTFScoreboard/ModActor.ModActor_C:MC_Scoreboard
-- Same 38-field format as old MC_Sync:
--   [1]=timer [2]=RedScore [3]=BlueScore
--   [4]=Red1Name [5]=Red1Class [6]=Red1Kills [7]=Red1Deaths [8]=Red1Flags
--   [9]=Red2Name ... [14]=Red3Name ... [19]=Blue1Name ... [24]=Blue2Name ... [29]=Blue3Name
--   [34]=RedFlagState [35]=BlueFlagState [36-38]=Powerup1/2/3Active
-- ============================================================================
local mc_scoreboard_registered = false

local function register_mc_scoreboard_hook()
    if mc_scoreboard_registered then return true end
    local ma = FindFirstOf("ModActor_C")
    if not ma or not ma:IsValid() then return false end

    local ok = pcall(function()
        RegisterHook("/Game/Mods/CTFScoreboard/ModActor.ModActor_C:MC_Scoreboard", function(self, data_param)
            _activate_wilderena()
            pcall(function()
                local raw = nil
                pcall(function() raw = data_param:get():ToString() end)
                if not raw or raw == "" then return end

                local fields = {}
                for f in (raw .. "|"):gmatch("([^|]*)|") do
                    table.insert(fields, f)
                end
                if #fields < 35 then return end

                game_state.timer = fields[1] or "0:00"
                game_state.red_torches = tonumber(fields[2]) or 0
                game_state.blue_torches = tonumber(fields[3]) or 0

                -- Player data: 6 slots, 5 fields each, starting at index 4
                -- Slots: Red1=4, Red2=9, Red3=14, Blue1=19, Blue2=24, Blue3=29
                local names_changed = false
                local slot_offsets = {4, 9, 14, 19, 24, 29}
                for slot = 1, 6 do
                    local base = slot_offsets[slot]
                    local name = fields[base] or ""
                    local old = game_state.players[slot] and game_state.players[slot].name or ""
                    if name ~= old and name ~= "" then names_changed = true end
                    game_state.players[slot] = {
                        name = name,
                        class = fields[base + 1] or "",
                        kills = tonumber(fields[base + 2]) or 0,
                        deaths = tonumber(fields[base + 3]) or 0,
                        flags = tonumber(fields[base + 4]) or 0,
                    }
                end

                -- Flag + powerup state (also carried in scoreboard for late-joining clients)
                game_state.red_flag = fields[34] or "base"
                game_state.blue_flag = fields[35] or "base"
                game_state.powerups[1] = (fields[36] == "1")
                game_state.powerups[2] = (fields[37] == "1")
                game_state.powerups[3] = (fields[38] == "1")

                if names_changed then
                    ExecuteInGameThread(function()
                        pcall(refresh_player_cache)
                    end)
                end
            end)
        end)
    end)

    if ok then
        mc_scoreboard_registered = true
        print("[WilderenaClient] MC_Scoreboard hook registered\n")
        return true
    end
    return false
end

-- ============================================================================
-- OnPlayerDeath HOOK — death VFX (instant, event-driven)
-- ============================================================================
local death_hook_registered = false

local function try_register_death_hook()
    if death_hook_registered then return true end
    local player = FindFirstOf("BP_PlayerCharacter_C")
    if not player or not player:IsValid() then return false end

    local ok, err = pcall(function()
        RegisterHook("/Game/Gameplay/Character/Player/BP_PlayerCharacter.BP_PlayerCharacter_C:OnPlayerDeath", function(self)
        if not _wilderena_active then return end
        pcall(function()
            local victim = self:get()
            if not victim or not victim:IsValid() then return end
            local vpos = victim:K2_GetActorLocation()
            if not vpos then return end

            -- Resolve killer via damage component (same attribution as server combat.lua)
            local killer = nil
            local victim_ctrl = nil
            pcall(function() victim_ctrl = victim:GetInstigatorController() end)
            local victim_id = nil
            pcall(function() victim_id = victim_ctrl.PlayerState.PlayerId end)

            local dmg = victim.BP_Components_PlayerDamage
            if dmg then
                -- Method 1: LastDamageInstigatorServer
                pcall(function()
                    local ins = dmg.LastDamageInstigatorServer
                    if ins and ins:IsValid() and ins:GetFullName():find("PlayerCharacter") then
                        killer = ins
                    end
                end)
                -- Method 2: LastDamageEvent.Instigator
                if not killer then
                    pcall(function()
                        local lde = dmg.LastDamageEvent
                        if lde and lde.Instigator and lde.Instigator:IsValid() and lde.Instigator:GetFullName():find("PlayerCharacter") then
                            killer = lde.Instigator
                        end
                    end)
                end
            end

            -- If killer is victim (simkill) or nil, still fire VFX on victim
            local killer_id = nil
            if killer then
                pcall(function() killer_id = killer:GetInstigatorController().PlayerState.PlayerId end)
            end
            print(string.format("[VFX] OnPlayerDeath: victim=P%s killer=P%s\n",
                tostring(victim_id), tostring(killer_id)))

            ExecuteInGameThread(function()
                pcall(function()
                    local world = victim:GetWorld()
                    -- Death dissolve on victim
                    if world then
                        spawn_niagara(world,
                            "/Game/Art/VFX/Library/Character/Shared/Death", "NS_CharacterDespawn",
                            vpos, nil)
                    end
                    -- SkillLevelUp on killer (covers real PvP kills + simkill where victim==killer)
                    if killer and killer:IsValid() then
                        spawn_vfx_at_player(killer,
                            "/Game/Art/VFX/Library/Character", "NS_SkillLevelUp_v02", 50)
                    else
                        -- Fallback for simkill with no damage source — fire on victim
                        spawn_vfx_at_player(victim,
                            "/Game/Art/VFX/Library/Character", "NS_SkillLevelUp_v02", 50)
                    end
                end)
            end)
        end)
    end)
    end)
    if ok then
        death_hook_registered = true
        print("[WilderenaClient] OnPlayerDeath hook registered\n")
        return true
    else
        -- Silent retry — BP might not be loaded yet
        return false
    end
end

-- ============================================================================
-- Multicast_Respawn HOOK — respawn VFX (instant, event-driven)
-- ============================================================================
local respawn_hook_registered = false

local function try_register_respawn_hook()
    if respawn_hook_registered then return true end
    local player = FindFirstOf("BP_PlayerCharacter_C")
    if not player or not player:IsValid() then return false end

    local ok, err = pcall(function()
        RegisterHook("/Script/Dominion.PlayerRespawnComponent:Multicast_Respawn", function(self, loc, rot)
            if not _wilderena_active then return end
            pcall(function()
                print("[VFX] Multicast_Respawn fired\n")
                -- Find the player that this component belongs to
                local respawn_comp = self:get()
                ExecuteWithDelay(100, function()
                    ExecuteInGameThread(function()
                        pcall(function()
                            -- Get the owning player
                            local owner = nil
                            pcall(function() owner = respawn_comp:GetOwner() end)
                            if not owner or not owner:IsValid() then
                                -- Fallback: find by component match
                                local all = FindAllOf("BP_PlayerCharacter_C")
                                if all then
                                    for _, p in pairs(all) do
                                        pcall(function()
                                            local rc = p.PlayerRespawnComponent
                                            if rc == respawn_comp then owner = p end
                                        end)
                                    end
                                end
                            end
                            if owner and owner:IsValid() then
                                -- Fire SkillLevelUp on the respawning player
                                spawn_vfx_at_player(owner,
                                    "/Game/Art/VFX/Library/Character", "NS_SkillLevelUp_v02", 50)
                                -- Also teleport-out VFX at their new position
                                local p_pos = owner:K2_GetActorLocation()
                                if p_pos then
                                    local world = owner:GetWorld()
                                    if world then
                                        spawn_niagara_with_load(world,
                                            "/Game/Art/VFX/Library/Survival/Magic/Lodestone_Teleport", "NS_Teleport_Out",
                                            p_pos, nil)
                                    end
                                end
                                print("[VFX] Respawn VFX fired on player\n")
                            end
                        end)
                    end)
                end)
            end)
        end)
    end)
    if ok then
        respawn_hook_registered = true
        print("[WilderenaClient] Multicast_Respawn hook registered\n")
        return true
    end
    return false
end

-- ============================================================================
-- BUILD BLOCKER (client-side)
-- When builder_allowed is false, kick the LOCAL player out of build mode so the
-- B tab can't be used. Reactive (<= loop interval) — the tab may flash briefly
-- before closing; a frame-perfect block would need a hook on the build-enter fn.
-- Default is BLOCKED; press F9 (or send admin "builder|enable") to allow building
-- for dungeon authoring.
-- ============================================================================
local _bb_local_pawn = nil
local function _bb_get_local_pawn()
    local ok = false
    pcall(function() ok = _bb_local_pawn and _bb_local_pawn:IsValid() end)
    if ok then return _bb_local_pawn end
    _bb_local_pawn = nil
    local players = FindAllOf("BP_PlayerCharacter_C")
    if not players then return nil end
    for _, p in pairs(players) do
        local is_local = false
        local called = pcall(function() is_local = p:IsLocallyControlled() end)
        if (not called) or is_local then  -- if IsLocallyControlled unavailable, assume local (client has 1 controllable pawn)
            local valid = false
            pcall(function() valid = p and p:IsValid() end)
            if valid then _bb_local_pawn = p; return p end
        end
    end
    return nil
end

local function enforce_build_block()
    if game_state.builder_allowed then return end
    local p = _bb_get_local_pawn()
    if not p then return end
    pcall(function()
        local ctrl = p:GetInstigatorController()
        if not ctrl or not ctrl:IsValid() then return end
        local bmc = ctrl.BuildModeComponent
        if not bmc or not bmc:IsValid() then return end
        local cur = 0
        pcall(function() cur = bmc.CurrentBuildMode end)
        if cur and cur ~= 0 then
            pcall(function() bmc:ExitAnyMode() end)
            pcall(function() bmc:Server_SetBuildMode(0) end)
            pcall(function() bmc.CurrentBuildMode = 0 end)
        end
    end)
end

-- ============================================================================
-- SINGLE UNIFIED HOOK REGISTRATION RETRY LOOP
-- One LoopAsync that tries all hooks, stops when all succeed.
-- ============================================================================
LoopAsync(2000, function()
    local all_done = true
    if not register_mc_event_hook() then all_done = false end
    if not register_mc_timer_hook() then all_done = false end
    if not register_mc_scoreboard_hook() then all_done = false end
    if not try_register_death_hook() then all_done = false end
    if not try_register_respawn_hook() then all_done = false end
    if all_done then
        print("[WilderenaClient] All hooks registered\n")

        -- Build blocker (client-side): enforce whenever builder_allowed is false.
        LoopAsync(150, function()
            pcall(enforce_build_block)
            return false  -- run for the whole session
        end)
        print(string.format("[WilderenaClient] Build blocker ENABLED (client-side, builder_allowed=%s; F9 toggles)\n", tostring(game_state.builder_allowed)))

        -- Pin Niagara assets now that world is confirmed valid
        -- Stagger 3 attempts (2s, 7s, 12s after hooks) to catch late-streaming assets
        for pin_attempt = 1, 3 do
            ExecuteWithDelay(pin_attempt * 5000 - 3000, function()
                ExecuteInGameThread(function()
                    pcall(function()
                        preload_powerup_assets()
                        pin_niagara_assets()
                    end)
                end)
            end)
        end
        return true  -- stop loop
    end
    return false
end)

-- ============================================================================
-- KEYBINDS
-- ============================================================================

-- ============================================================================
-- VFX TEST KEYBINDS  (NUM_4 = Fellhollow, NUM_5 = DowdunReach)
-- Each press spawns the NEXT VFX in the list at the local player and logs its
-- name + index, so you can step through every effect in the content pack.
-- ============================================================================
local _VFX_TEST_FELLHOLLOW = {
    "/Game/Art/VFX/Library/Env/Fellhollow/Withering/ImaruGaze/NS_VFX_Character_ImaruGaze_Burst",
    "/Game/Art/VFX/Library/Env/Fellhollow/Withering/ImaruGaze/NS_VFX_Character_ImaruGaze_OnCharacter",
    "/Game/Art/VFX/Library/Env/Fellhollow/cleansingPool/NS_VFX_CleansingPool",
    "/Game/Art/VFX/Library/Env/Fellhollow/cleansingPool/NS_VFX_CleansingPoolActivate",
    "/Game/Art/VFX/Library/Env/Fellhollow/Withering/SpectralDoor/NS_VFX_SpectralDoorMist",
    "/Game/Art/VFX/Library/Env/Fellhollow/ImaruSeal/NS_VFX_TowerSealBreak_CloseRange",
    "/Game/Art/VFX/Library/Env/Fellhollow/ImaruSeal/NS_VFX_TowerSealBreak_Door",
}

local _VFX_TEST_DOWDUN = {
    "/DowdunReach/Art/VFX/Library/Combat/Ranged/EnchantedBolts/Poison/NS_ArrowPoison_Cast",
    "/DowdunReach/Art/VFX/Library/Combat/Ranged/EnchantedBolts/Poison/NS_ArrowPoison_Impact",
    "/DowdunReach/Art/VFX/Library/Combat/Ranged/EnchantedBolts/Poison/NS_ArrowPoison_Venom",
    "/DowdunReach/Art/VFX/Enemies/Zam_Mage/ZamorakFlames/Charge/NS_Attack_ZamorakMage_Charge_Staff_Looping",
    "/DowdunReach/Art/VFX/Library/Combat/Ranged/ZamorakStaff/NS_Attack_ZamorakMage_Player_SmokeGround",
    "/DowdunReach/Art/VFX/Enemies/BlackKnight/Corruption/NS_BlackKnight_Corruption_Method1",
    "/DowdunReach/Art/VFX/Enemies/BlackKnight/Visor_Glint/NS_DeathKnight_Glint",
    "/DowdunReach/Art/VFX/Enemies/Hit_Effects/NS_Hit_Fire",
    "/DowdunReach/Art/VFX/Enemies/LesserBlueDragon/Shock_Projectile/NS_LesserBlueDragon_ImpactProjectile",
    "/DowdunReach/Art/VFX/Enemies/Zam_Mage/Casting/NS_ZamMage_Summon_Cast",
    "/DowdunReach/Art/VFX/Enemies/Zam_Mage/Casting/NS_ZamMage_Summon_Cast_03",
    "/DowdunReach/Art/VFX/Enemies/Zam_Mage/ZamorakFlames/NS_ZamorakFlames_AoE",
    "/DowdunReach/Art/VFX/Library/Combat/Ranged/ZamorakStaff/NS_ZamorakFlames_Player_AoE",
}

local _vfx_test_idx = { fell = 0, dow = 0 }
local function _vfx_test_cycle(list, key, label)
    if not list or #list == 0 then return end
    _vfx_test_idx[key] = (_vfx_test_idx[key] % #list) + 1
    local pkg = list[_vfx_test_idx[key]]
    local folder = pkg:match("^(.*)/[^/]+$")
    local name = pkg:match("/([^/]+)$")
    local i, n = _vfx_test_idx[key], #list
    local done = false
    -- Niagara assets may stream in async, so retry the load+spawn across a few delays.
    for _, d in ipairs({ 0, 500, 1200, 2200 }) do
        ExecuteWithDelay(d, function()
            if done then return end
            ExecuteInGameThread(function()
                if done then return end
                local p = _bb_get_local_pawn() or FindFirstOf("BP_PlayerCharacter_C")
                if not p or not p:IsValid() then return end
                local world = p:GetWorld()
                local pos = p:K2_GetActorLocation()
                local sp = { X = pos.X, Y = pos.Y, Z = pos.Z + 120 }
                local comp = spawn_niagara_with_load(world, folder, name, sp, nil)
                if comp then
                    done = true
                    print(string.format("[VFX TEST] %s [%d/%d] %s -> OK (%dms)", label, i, n, name, d) .. string.char(10))
                end
            end)
        end)
    end
    ExecuteWithDelay(2700, function()
        if not done then print(string.format("[VFX TEST] %s [%d/%d] %s -> FAIL (not loadable here)", label, i, n, name) .. string.char(10)) end
    end)
end

-- ============================================================================
-- FOG STYLE CYCLER (key 7): each press removes the previous fog and spawns the
-- next style at the player, logging its name -> compare looks. LocalFogVolume is
-- the engine volumetric (area = actor scale); the rest are the game's own fog
-- Blueprints. To size to a specific area, give coords and we set position+scale.
-- ============================================================================
local _fog_styles = {
    { name = "LocalFogVolume (swamp preset)", engine = true },
    { name = "DistantOpaqueFog_Toxic",  path = "/Game/Gameplay/World/Ambience/Components/BP_DistantOpaqueFog_Toxic.BP_DistantOpaqueFog_Toxic_C" },
    { name = "DistantOpaqueFog",        path = "/Game/Gameplay/World/Ambience/Components/BP_DistantOpaqueFog.BP_DistantOpaqueFog_C" },
    { name = "GroundFog_v03",           path = "/Game/Art/Env/Lighting/BPs/BP_GroundFog_v03.BP_GroundFog_v03_C" },
    { name = "GroundFog_Plane",         path = "/Game/Art/Env/Lighting/BPs/BP_GroundFog_Plane.BP_GroundFog_Plane_C" },
    { name = "HeightFog_FH (Fellhollow)", path = "/Game/Art/Env/Lighting/BP_HeightFog_FH.BP_HeightFog_FH_C" },
    { name = "HeightFog (base)",        path = "/Game/Art/Env/Lighting/BP_HeightFog.BP_HeightFog_C" },
    { name = "Nexus_Fog",               path = "/Game/Art/Env/Lighting/BP_Nexus_Fog.BP_Nexus_Fog_C" },
    { name = "DistanceFog_plane_01",    path = "/Game/Art/Env/Lighting/BPs/BP_DistanceFog_plane_01.BP_DistanceFog_plane_01_C" },
}
local _fog_idx = 0
local _fog_actor = nil
RegisterKeyBind(Key.SEVEN, function()
    ExecuteInGameThread(function()
        pcall(function()
            if _fog_actor and _fog_actor:IsValid() then pcall(function() _fog_actor:K2_DestroyActor() end) end
            _fog_actor = nil
            _fog_idx = (_fog_idx % #_fog_styles) + 1
            local style = _fog_styles[_fog_idx]
            local p = _bb_get_local_pawn() or FindFirstOf("BP_PlayerCharacter_C")
            if not p or not p:IsValid() then return end
            local world = p:GetWorld()
            local pos = p:K2_GetActorLocation()
            local sp = { X = pos.X, Y = pos.Y, Z = pos.Z - 50 }
            local cls = nil
            if style.engine then
                cls = StaticFindObject("/Script/Engine.LocalFogVolume")
            else
                cls = StaticFindObject(style.path)
                if not cls then
                    pcall(function() LoadAsset((style.path:gsub("%.[^.]*$", ""))) end)
                    cls = StaticFindObject(style.path)
                end
            end
            if not cls then print("[FOG STYLE] " .. _fog_idx .. "/" .. #_fog_styles .. " " .. style.name .. " -> class NOT FOUND" .. string.char(10)); return end
            local a = world:SpawnActor(cls, sp, {})
            if not a or not a:IsValid() then print("[FOG STYLE] " .. style.name .. " -> spawn FAILED" .. string.char(10)); return end
            _fog_actor = a
            if style.engine then
                pcall(function() a:SetActorScale3D({ X = 40.0, Y = 40.0, Z = 8.0 }) end)
                local comp = a.LocalFogVolumeVolume
                if comp and comp:IsValid() then
                    pcall(function() comp:SetHeightFogExtinction(3.0) end)
                    pcall(function() comp:SetHeightFogFalloff(0.5) end)
                    pcall(function() comp:SetFogAlbedo({ R = 0.42, G = 0.5, B = 0.4, A = 1.0 }) end)
                end
            end
            print("[FOG STYLE] " .. _fog_idx .. "/" .. #_fog_styles .. " " .. style.name .. " -> OK" .. string.char(10))
        end)
    end)
end)

RegisterKeyBind(Key.EIGHT, function() _vfx_test_cycle(_VFX_TEST_FELLHOLLOW, "fell", "Fellhollow") end)
RegisterKeyBind(Key.NINE, function() _vfx_test_cycle(_VFX_TEST_DOWDUN, "dow", "DowdunReach") end)

-- F9 = toggle build permission (for dungeon authoring). Default is BLOCKED.
RegisterKeyBind(Key.F9, function()
    game_state.builder_allowed = not game_state.builder_allowed
    print(string.format("[WilderenaClient] builder_allowed -> %s (F9)\n", tostring(game_state.builder_allowed)))
end)

-- F3 = Test spawn red + blue standing torches at flag positions
RegisterKeyBind(Key.F3, function()
    if not _wilderena_active then return end
    ExecuteInGameThread(function()
        pcall(function()
            local player = FindFirstOf("BP_PlayerCharacter_C")
            if not player then return end
            local world = player:GetWorld()

            local ppos = player:K2_GetActorLocation()

            for _, team in ipairs({"red", "blue"}) do
                local pos = FLAG_POSITIONS[team]
                local color = (team == "red") and "Red" or "Blue"

                -- Standing torch (SpawnActor)
                local torch = FindFirstOf("BP_BaseBuilding_TorchStanding_" .. color .. "_C")
                if torch and torch:IsValid() then
                    local a = world:SpawnActor(torch:GetClass(), {X = pos.X, Y = pos.Y, Z = pos.Z - 130}, {})
                    if a then
                        pcall(function() a:SetActorEnableCollision(false) end)
                        pcall(function() a.bCanBeDamaged = false end)
                        print("[VFX] " .. color .. " standing torch spawned\n")
                    end
                else
                    print("[VFX] No " .. color .. " torch template found\n")
                end

                -- Dragonfire beam (Niagara) — test different rolls
                local z_off = (team == "blue") and -220 or -1100
                local bv = {sx=1.0, sy=1.0, sz=1.0}
                local test_roll, test_pitch
                if team == "red" then
                    test_roll = 94.2
                    test_pitch = -1.3
                    bv.label = "red R=94.2 P=-1.3"
                else
                    test_roll = 94.25
                    test_pitch = 0.2
                    bv.label = "blue R=94.25 P=0.2"
                end
                bv.pitch = test_pitch
                bv.roll = test_roll
                local beam_pos = {X = pos.X, Y = pos.Y, Z = ppos.Z + z_off}
                local beam_rot = {Pitch = bv.pitch, Yaw = 0, Roll = test_roll}
                local beam_scale = {X = bv.sx, Y = bv.sy, Z = bv.sz}
                -- Custom spawn with scale
                local full_path = "/Game/Art/VFX/Library/Character/Dragons/Generic/NS_VFX_Dragonfire_Laser.NS_VFX_Dragonfire_Laser"
                local beam_sys = nil
                pcall(function() beam_sys = StaticFindObject(full_path) end)
                if not beam_sys then
                    pcall(function() LoadAsset("/Game/Art/VFX/Library/Character/Dragons/Generic/NS_VFX_Dragonfire_Laser") end)
                    pcall(function() beam_sys = StaticFindObject(full_path) end)
                end
                if beam_sys and get_niagara_lib() then
                    get_niagara_lib():SpawnSystemAtLocation(world, beam_sys, beam_pos, beam_rot, beam_scale, true, true, 0, false)
                end
                print("[VFX] " .. color .. " " .. bv.label .. "\n")

                -- Blue Seal ring (SpawnActor)
                pcall(function()
                    local seal = FindFirstOf("BP_Seal_Switchable_C")
                    if seal and seal:IsValid() then
                        local seal_pos = {X = ppos.X, Y = ppos.Y, Z = ppos.Z}
                        local a = world:SpawnActor(seal:GetClass(), seal_pos, {})
                        if a then
                            if not vfx_state._seal_idx then vfx_state._seal_idx = 0 end
                            vfx_state._seal_idx = vfx_state._seal_idx + 1
                            local seal_rots = {
                                {P=0,   Y=0,   R=0,   label="default"},
                                {P=90,  Y=0,   R=0,   label="P=90"},
                                {P=0,   Y=90,  R=0,   label="Y=90"},
                                {P=0,   Y=0,   R=90,  label="R=90"},
                                {P=90,  Y=90,  R=0,   label="P=90 Y=90"},
                                {P=90,  Y=0,   R=90,  label="P=90 R=90"},
                                {P=0,   Y=90,  R=90,  label="Y=90 R=90"},
                                {P=45,  Y=0,   R=0,   label="P=45"},
                                {P=0,   Y=45,  R=0,   label="Y=45"},
                                {P=0,   Y=0,   R=45,  label="R=45"},
                            }
                            local si = ((vfx_state._seal_idx - 1) % #seal_rots) + 1
                            local sr = seal_rots[si]
                            pcall(function() a:K2_SetActorLocationAndRotation(seal_pos, {Pitch=sr.P, Yaw=sr.Y, Roll=sr.R}, false, {}, true) end)
                            pcall(function() a:SetActorEnableCollision(false) end)
                            print("[VFX] seal #" .. si .. " " .. sr.label .. "\n")
                        end
                    else
                        print("[VFX] No BP_Seal_Switchable_C template found\n")
                    end
                end)

            end
        end)
    end)
end)

-- Num1 = Cycle through character VFX at player position
local char_vfx = {
    {"/Game/Art/VFX/Library/Character/Shared/Death", "NS_CharacterRespawn", "Respawn"},
    {"/Game/Art/VFX/Library/Character/Shared/Death", "NS_CharacterDespawn", "Despawn"},
    {"/Game/Art/VFX/Library/Survival/Magic/Lodestone_Teleport", "NS_Teleport_Out", "Teleport Out"},
    {"/Game/Art/VFX/Library/Character", "NS_SkillLevelUp_v02", "Skill Level Up"},
    {"/Game/Art/VFX/Library/Character/Beast_Druid/GarouPride", "NS_Beast_Druid_GarouPride_Heal_Looping", "Heal Loop"},
    {"/Game/Art/VFX/Library/Combat/Melee/ImaruShield", "NS_VFX_Imaru_Shield_Pulse", "Shield Pulse"},
    {"/Game/Art/VFX/Library/Combat/Melee/ImaruShield", "NS_VFX_ImaruShield_Special_Parry", "Shield Parry"},
    {"/Game/Art/VFX/Library/Combat/Ranged/HunterPulse", "NS_HunterSense_Shockwave_On", "Hunter Pulse On"},
    {"/Game/Art/VFX/Library/Combat/Ranged/HunterPulse", "NS_HunterSense_Shockwave_Off", "Hunter Pulse Off"},
    {"/Game/Art/VFX/Library/Combat/Magic/Fire/Attack_04", "NS_SpawnProyectiles_FromSky", "Fire From Sky"},
    {"/Game/Art/VFX/Library/Character/NS_Character_Despawn_AI", "NS_Character_Despawn_AI", "AI Despawn"},
    {"/Game/Art/VFX/Library/Combat/Melee/DragonShieldPoison", "NS_PoisonParry_Cast", "Poison Parry Cast"},
    {"/Game/Art/VFX/Library/Combat/Melee/DragonShieldPoison", "NS_PoisonParry_AoE", "Poison Parry AoE"},
    {"/Game/Art/VFX/Library/Character/Imaru/BossFight/SpectralVines", "NS_VFX_VinesSpawn", "Vines Spawn"},
}
local char_vfx_idx = 0

RegisterKeyBind(Key.NUM_ONE, function()
    if not _wilderena_active then return end
    ExecuteInGameThread(function()
        pcall(function()
            local player = FindFirstOf("BP_PlayerCharacter_C")
            if not player then return end
            local pos = player:K2_GetActorLocation()
            local world = player:GetWorld()
            char_vfx_idx = char_vfx_idx + 1
            if char_vfx_idx > #char_vfx then char_vfx_idx = 1 end
            local vfx = char_vfx[char_vfx_idx]
            local result = spawn_niagara(world, vfx[1], vfx[2], {X = pos.X, Y = pos.Y, Z = pos.Z + 50}, nil)
            print("[CHAR VFX] #" .. char_vfx_idx .. "/" .. #char_vfx .. ": " .. vfx[3] .. " -> " .. (result and "OK" or "FAIL") .. "\n")
        end)
    end)
end)

-- Num2 = Cycle through fade/attached character effects
local fade_vfx = {
    {"/Game/Art/VFX/Library/Character/Shared/Death", "NS_CharacterDespawn", "Despawn/FadeOut"},
    {"/Game/Art/VFX/Library/Character/Shared/Death", "NS_CharacterRespawn", "Respawn/FadeIn"},
    {"/Game/Art/VFX/Library/Character/StatusEffect/OnFire", "NS_PlayerCharacter_OnFire_Digi1", "On Fire Dissolve"},
    {"/Game/Art/VFX/Library/Spells/Surge", "NS_Surge_Out", "Surge Out"},
    {"/Game/Art/VFX/Library/Spells/Surge", "NS_SurgeTrail_A", "Surge Trail"},
    {"/Game/Art/VFX/Library/Spells/Surge", "NS_Surge_Magic_A", "Surge Magic"},
    {"/Game/Art/VFX/Library/Spells/Surge", "NS_Surge_Burst", "Surge Burst"},
    {"/Game/Art/VFX/Library/Spells/Windstep", "NS_Windstep_Launch", "Windstep Launch"},
    {"/Game/Art/VFX/Library/Spells/Windstep", "NS_Windstep_Slowfall_Looping", "Windstep Slowfall"},
    {"/Game/Art/VFX/Library/Character/StatusEffect", "NS_Character_Bleed", "Bleed"},
    {"/Game/Art/VFX/Library/Character/StatusEffect", "NS_Character_Poison", "Poison"},
    {"/Game/Art/VFX/Library/Character/StatusEffect", "NS_Character_Shocked", "Shocked"},
    {"/Game/Art/VFX/Library/Character/StatusEffect", "NS_Character_Cold", "Cold"},
    {"/Game/Art/VFX/Library/Character/StatusEffect/Withered", "NS_Character_Wither_Loop", "Wither Loop"},
    {"/Game/Art/VFX/Library/Character/StatusEffect", "NS_Character_Toxified", "Toxified"},
    {"/Game/Art/VFX/Library/Spells/EnchantWeapon", "NS_EnchantWeapon_Fire", "Enchant Fire"},
    {"/Game/Art/VFX/Library/Spells/EnchantWeapon", "NS_EnchantWeapon_Wind", "Enchant Wind"},
    {"/Game/Art/VFX/Library/Character/Beast_Druid/GarouPride", "NS_Beast_Druid_GarouPride_Heal_Looping", "Heal Aura"},
    {"/Game/Art/VFX/Library/Spells/MagicFocus", "NS_MagicFocus_Special", "Magic Focus"},
    {"/Game/Art/VFX/Library/Spells/Confuse", "NS_Confuse_Begins", "Confuse"},
    {"/Game/Art/VFX/Library/Spells/Snare", "NS_Snare_Begins", "Snare"},
}
local fade_vfx_idx = 0

RegisterKeyBind(Key.NUM_TWO, function()
    if not _wilderena_active then return end
    ExecuteInGameThread(function()
        pcall(function()
            local player = FindFirstOf("BP_PlayerCharacter_C")
            if not player then return end
            local pos = player:K2_GetActorLocation()
            local world = player:GetWorld()
            fade_vfx_idx = fade_vfx_idx + 1
            if fade_vfx_idx > #fade_vfx then fade_vfx_idx = 1 end
            local vfx = fade_vfx[fade_vfx_idx]
            local result = spawn_niagara(world, vfx[1], vfx[2], {X = pos.X, Y = pos.Y, Z = pos.Z}, nil)
            print("[FADE VFX] #" .. fade_vfx_idx .. "/" .. #fade_vfx .. ": " .. vfx[3] .. " -> " .. (result and "OK" or "FAIL") .. "\n")
        end)
    end)
end)

-- Num3 = Cycle through character blueprint functions
local char_funcs = {
    {func = "PlayRespawnVFX", label = "PlayRespawnVFX (dissolve in)"},
    {func = "PlayDespawnVFX", label = "PlayDespawnVFX (dissolve out)"},
    {func = "DissolveTeleport", label = "DissolveTeleport (full dissolve TP)"},
    {func = "BP_PlayTeleportBeginVFXOnPlayer", label = "TeleportBeginVFX (start TP)"},
    {func = "BP_PlayTeleportEndVFXOnPlayer", label = "TeleportEndVFX (end TP)"},
    {func = "OnPlayerDeath", label = "OnPlayerDeath"},
    {func = "OnPlayerRespawn", label = "OnPlayerRespawn (full respawn)"},
    {func = "OnHealthPotionConsume", label = "OnHealthPotionConsume (potion FX)"},
    {func = "PotionFXDeactivate", label = "PotionFXDeactivate (stop potion)"},
    {func = "BP_OnSkillLevelUp", label = "BP_OnSkillLevelUp (level up FX)"},
    {func = "HandleOnEnteredCriticalSurvivalState", label = "EnteredCriticalState (low HP)"},
    {func = "HandleOnExitedCriticalSurvivalState", label = "ExitedCriticalState (HP recovered)"},
}
local char_func_idx = 0

RegisterKeyBind(Key.NUM_THREE, function()
    if not _wilderena_active then return end
    ExecuteInGameThread(function()
        pcall(function()
            local player = FindFirstOf("BP_PlayerCharacter_C")
            if not player then return end
            char_func_idx = char_func_idx + 1
            if char_func_idx > #char_funcs then char_func_idx = 1 end
            local cf = char_funcs[char_func_idx]
            pcall(function() player[cf.func](player) end)
            print("[CHAR FUNC] #" .. char_func_idx .. ": " .. cf.label .. "\n")
        end)
    end)
end)

-- Num0 = Scan nearby interactable actors (within 3000 units)
RegisterKeyBind(Key.NUM_ZERO, function()
    if not _wilderena_active then return end
    ExecuteInGameThread(function()
        pcall(function()
            local player = FindFirstOf("BP_PlayerCharacter_C")
            if not player then return end
            local ppos = player:K2_GetActorLocation()
            local world = player:GetWorld()

            print("[SCAN] === Nearby interactable actors ===\n")
            -- Scan broad actor classes
            local scan_classes = {"BP_AnimaVent_C", "BP_Crafting_Rune_Altar_C", "WorldActorBase", "BP_WorldActorBase_C", "InteractableActor"}
            for _, cn in ipairs(scan_classes) do
                local all = FindAllOf(cn)
                if all then
                    for _, a in pairs(all) do
                        pcall(function()
                            if a and a:IsValid() then
                                local loc = a:K2_GetActorLocation()
                                local dx = loc.X - ppos.X
                                local dy = loc.Y - ppos.Y
                                local dist = math.sqrt(dx*dx + dy*dy)
                                if dist < 3000 then
                                    local cls_name = a:GetClass():GetFName():ToString()
                                    print("[SCAN] " .. cls_name .. " dist=" .. string.format("%.0f", dist) .. " pos=" .. string.format("%.0f,%.0f,%.0f", loc.X, loc.Y, loc.Z) .. "\n")
                                end
                            end
                        end)
                    end
                end
            end

            -- Also scan ALL actors and filter by class name for anything interesting
            local all_actors = FindAllOf("Actor")
            if all_actors then
                local found = 0
                for _, a in pairs(all_actors) do
                    if found > 30 then break end
                    pcall(function()
                        if a and a:IsValid() then
                            local loc = a:K2_GetActorLocation()
                            local dx = loc.X - ppos.X
                            local dy = loc.Y - ppos.Y
                            local dist = math.sqrt(dx*dx + dy*dy)
                            if dist < 1500 then
                                local cls_name = a:GetClass():GetFName():ToString()
                                if cls_name:find("Vent") or cls_name:find("Essence") or cls_name:find("Rune") or cls_name:find("Seal") or cls_name:find("Altar") or cls_name:find("Obelisk") or cls_name:find("Portal") or cls_name:find("Node") or cls_name:find("Interactable") or cls_name:find("WorldActor") then
                                    found = found + 1
                                    print("[SCAN] NEAR: " .. cls_name .. " dist=" .. string.format("%.0f", dist) .. "\n")
                                end
                            end
                        end
                    end)
                end
            end
            print("[SCAN] === Done ===\n")
        end)
    end)
end)

-- F5 = Record spawn point to file + console
local pos_counter = 0
local spawn_file = "ue4ss/Mods/WilderenaClient/recorded_spawns.txt"
RegisterKeyBind(Key.F5, function()
    if not _wilderena_active then return end
    ExecuteInGameThread(function()
        pcall(function()
            local player = FindFirstOf("BP_PlayerCharacter_C")
            if not player then return end
            local pos = player:K2_GetActorLocation()
            pos_counter = pos_counter + 1
            local line = string.format("o(%.0f, %.0f, %.0f),", pos.X, pos.Y, pos.Z)
            print(string.format("[SPAWN #%d] %s\n", pos_counter, line))
            -- Append to file
            local f = io.open(spawn_file, "a")
            if f then
                f:write(string.format("-- #%d\n%s\n", pos_counter, line))
                f:close()
            end
        end)
    end)
end)

-- F8 = Spawn full powerup stack at all 3 positions
-- Each: astral orb + air orb + anima vent beam + wild anima (all SpawnActor, session-only)
local test_spawned = {}

RegisterKeyBind(Key.F8, function()
    if not _wilderena_active then return end
    ExecuteInGameThread(function()
        pcall(function()
            local player = FindFirstOf("BP_PlayerCharacter_C")
            if not player then return end
            local world = player:GetWorld()

            for i = 1, 3 do
                local pos = POWERUP_POSITIONS[i]
                local stack = {niagara = {}, actors = {}}

                -- All 5 elemental orbs (Niagara)
                local orb_z = pos.Z - 80
                local orb_types = {
                    {folder = "/Game/Art/VFX/Library/Env/AnimaVent/Astral", asset = "NS_Anima_Loop_Astral"},
                    {folder = "/Game/Art/VFX/Library/Env/AnimaVent/Air", asset = "NS_Anima_Loop_Air"},
                    {folder = "/Game/Art/VFX/Library/Env/AnimaVent/Fire", asset = "NS_Anima_Loop_Fire"},
                }
                for _, orb in ipairs(orb_types) do
                    local comp = spawn_niagara(world, orb.folder, orb.asset,
                        {X = pos.X, Y = pos.Y, Z = orb_z}, nil)
                    if comp then table.insert(stack.niagara, comp) end
                end

                -- AnimaVent beam (SpawnActor, session-only) — lowered 150 units
                pcall(function()
                    local vent = FindFirstOf("BP_AnimaVent_C")
                    if vent and vent:IsValid() then
                        local a = world:SpawnActor(vent:GetClass(), {X = pos.X, Y = pos.Y, Z = pos.Z - 820}, {})
                        if a then
                            pcall(function() a:SetActorEnableCollision(false) end)
                            table.insert(stack.actors, a)
                            print("[VFX] Vent beam spawned at Z=" .. (pos.Z - 820) .. "\n")
                        end
                    else
                        print("[VFX] No BP_AnimaVent_C template found!\n")
                    end
                end)

                -- Wild Anima (SpawnActor from existing template, session-only)
                pcall(function()
                    -- Try multiple class names
                    local anima = nil
                    local try_names = {
                        "BP_BaseBuilding_Decoration_Material_Anima_Wild_C",
                        "BP_BaseBuilding_Decoration_Material_Anima_Wild",
                        "BaseBuildingActor",
                    }
                    for _, name in ipairs(try_names) do
                        if not anima then
                            pcall(function()
                                local found = FindAllOf(name)
                                if found then
                                    for _, f in pairs(found) do
                                        local cn = f:GetClass():GetFName():ToString()
                                        if cn:find("Anima_Wild") then
                                            anima = f
                                            print("[VFX] Found anima via " .. name .. ": " .. cn .. "\n")
                                            break
                                        end
                                    end
                                end
                            end)
                        end
                    end
                    if anima and anima:IsValid() then
                        local cls = anima:GetClass()
                        print("[VFX] Wild Anima template found: " .. cls:GetFullName() .. "\n")
                        local a = world:SpawnActor(cls, {X = pos.X, Y = pos.Y, Z = pos.Z - 130}, {})
                        if a and a:IsValid() then
                            pcall(function() a:SetActorEnableCollision(false) end)
                            pcall(function() a.bCanBeDamaged = false end)
                            table.insert(stack.actors, a)
                            print("[VFX] Wild Anima spawned at powerup " .. i .. "\n")
                        else
                            print("[VFX] Wild Anima SpawnActor FAILED\n")
                        end
                    else
                        print("[VFX] No Wild Anima template found! Trying LoadAsset...\n")
                        pcall(function()
                            LoadAsset("/Game/Gameplay/BaseBuilding_New/BuildingPieces/Decorations/Materials/Basic/BP_BaseBuilding_Decoration_Material_Anima_Wild")
                        end)
                        local cls = nil
                        pcall(function()
                            cls = StaticFindObject("/Game/Gameplay/BaseBuilding_New/BuildingPieces/Decorations/Materials/Basic/BP_BaseBuilding_Decoration_Material_Anima_Wild.BP_BaseBuilding_Decoration_Material_Anima_Wild_C")
                        end)
                        if cls and cls:IsValid() then
                            local a = world:SpawnActor(cls, {X = pos.X, Y = pos.Y, Z = pos.Z - 130}, {})
                            if a and a:IsValid() then
                                pcall(function() a:SetActorEnableCollision(false) end)
                                table.insert(stack.actors, a)
                                print("[VFX] Wild Anima spawned via LoadAsset\n")
                            else
                                print("[VFX] Wild Anima SpawnActor via LoadAsset FAILED\n")
                            end
                        else
                            print("[VFX] Wild Anima class not found even after LoadAsset\n")
                        end
                    end
                end)

                test_spawned[i] = stack
                print("[VFX] Powerup " .. i .. " full stack spawned\n")
            end
        end)
    end)
end)

-- F4 = Clear ALL powerup objects (test + existing world objects)
RegisterKeyBind(Key.F4, function()
    if not _wilderena_active then return end
    ExecuteInGameThread(function()
        pcall(function()
            local cleared = 0

            -- Clear tracked test spawns
            for i, stack in pairs(test_spawned) do
                if stack.niagara then
                    for _, comp in ipairs(stack.niagara) do
                        despawn_niagara(comp)
                        cleared = cleared + 1
                    end
                end
                if stack.actors then
                    for _, actor in ipairs(stack.actors) do
                        pcall(function()
                            if actor and actor:IsValid() then
                                actor:K2_DestroyActor()
                                cleared = cleared + 1
                            end
                        end)
                    end
                end
            end
            test_spawned = {}

            -- Clear wild anima NEAR powerup positions only (preserve templates)
            local anima_all = FindAllOf("BP_BaseBuilding_Decoration_Material_Anima_Wild_C")
            if anima_all then
                for _, a in pairs(anima_all) do
                    pcall(function()
                        if a and a:IsValid() then
                            local loc = a:K2_GetActorLocation()
                            for _, pp in ipairs(POWERUP_POSITIONS) do
                                local dx = math.abs(loc.X - pp.X)
                                local dy = math.abs(loc.Y - pp.Y)
                                if dx < 500 and dy < 500 then
                                    a:K2_DestroyActor()
                                    cleared = cleared + 1
                                    break
                                end
                            end
                        end
                    end)
                end
            end

            -- Clear mod-spawned AnimaVent beams near powerup positions
            local vents = FindAllOf("BP_AnimaVent_C")
            if vents then
                for _, v in pairs(vents) do
                    pcall(function()
                        if v and v:IsValid() then
                            local loc = v:K2_GetActorLocation()
                            for _, pp in ipairs(POWERUP_POSITIONS) do
                                local dx = math.abs(loc.X - pp.X)
                                local dy = math.abs(loc.Y - pp.Y)
                                if dx < 500 and dy < 500 then
                                    v:K2_DestroyActor()
                                    cleared = cleared + 1
                                    break
                                end
                            end
                        end
                    end)
                end
            end

            -- Clear all Niagara orb components from VFX state
            for i = 1, 3 do
                local orbs = vfx_state.powerup_orbs[i]
                if orbs then
                    if type(orbs) == "table" then
                        despawn_niagara(orbs.astral)
                        despawn_niagara(orbs.air)
                    else
                        despawn_niagara(orbs)
                    end
                    vfx_state.powerup_orbs[i] = nil
                    cleared = cleared + 1
                end
            end

            -- Kill ALL Niagara components near flag positions
            local nc_flags = FindAllOf("NiagaraComponent")
            if nc_flags then
                for _, comp in pairs(nc_flags) do
                    pcall(function()
                        if comp and comp:IsValid() then
                            local owner = comp:GetOwner()
                            if owner and owner:IsValid() then
                                local loc = owner:K2_GetActorLocation()
                                for _, team in ipairs({"red", "blue"}) do
                                    local fp = FLAG_POSITIONS[team]
                                    if math.abs(loc.X - fp.X) < 500 and math.abs(loc.Y - fp.Y) < 500 then
                                        comp:Deactivate()
                                        comp:DestroyComponent()
                                        cleared = cleared + 1
                                        break
                                    end
                                end
                            end
                        end
                    end)
                end
            end

            -- Clear torches near flag positions
            for _, tcn in ipairs({"BP_BaseBuilding_TorchStanding_Red_C", "BP_BaseBuilding_TorchStanding_Blue_C", "BP_BaseBuilding_TorchStanding_C"}) do
                local torches = FindAllOf(tcn)
                if torches then
                    for _, t in pairs(torches) do
                        pcall(function()
                            if t and t:IsValid() then
                                local loc = t:K2_GetActorLocation()
                                for _, team in ipairs({"red", "blue"}) do
                                    local fp = FLAG_POSITIONS[team]
                                    if math.abs(loc.X - fp.X) < 500 and math.abs(loc.Y - fp.Y) < 500 then
                                        t:K2_DestroyActor()
                                        cleared = cleared + 1
                                        break
                                    end
                                end
                            end
                        end)
                    end
                end
            end

            -- Kill ALL Niagara components near powerup positions
            local nc = FindAllOf("NiagaraComponent")
            if nc then
                for _, comp in pairs(nc) do
                    pcall(function()
                        if comp and comp:IsValid() then
                            local owner = comp:GetOwner()
                            if owner and owner:IsValid() then
                                local loc = owner:K2_GetActorLocation()
                                for _, pp in ipairs(POWERUP_POSITIONS) do
                                    local dx = math.abs(loc.X - pp.X)
                                    local dy = math.abs(loc.Y - pp.Y)
                                    if dx < 500 and dy < 500 then
                                        comp:Deactivate()
                                        comp:DestroyComponent()
                                        cleared = cleared + 1
                                        break
                                    end
                                end
                            end
                        end
                    end)
                end
            end

            print("[VFX] Cleared " .. cleared .. " objects (test + world + niagara)\n")
        end)
    end)
end)

-- F7 = Test spawn beams at both flag positions
RegisterKeyBind(Key.F7, function()
    if not _wilderena_active then return end
    ExecuteInGameThread(function()
        pcall(function()
            local player = FindFirstOf("BP_PlayerCharacter_C")
            if not player then return end
            local world = player:GetWorld()
            local ppos = player:K2_GetActorLocation()
            for _, team in ipairs({"red", "blue"}) do
                local pos = FLAG_POSITIONS[team]
                local z_off = (team == "blue") and -220 or -1100
                spawn_niagara(world,
                    "/Game/Art/VFX/Library/Character/Dragons/Generic", "NS_VFX_Dragonfire_Laser",
                    {X = pos.X, Y = pos.Y, Z = ppos.Z + z_off},
                    {Pitch = 0, Yaw = 0, Roll = 90})
                print("[VFX Test] " .. team .. " beam spawned\n")
            end
        end)
    end)
end)

-- F6 = Test beam at RED FLAG position
RegisterKeyBind(Key.F6, function()
    if not _wilderena_active then return end
    ExecuteInGameThread(function()
        pcall(function()
            local player = FindFirstOf("BP_PlayerCharacter_C")
            if not player then return end
            local world = player:GetWorld()
            local ppos = player:K2_GetActorLocation()
            print("[VFX] Player pos: " .. string.format("%.0f,%.0f,%.0f", ppos.X, ppos.Y, ppos.Z) .. "\n")
            -- Spawn at player position with same Roll=90 and Z-1100 offset
            local result = spawn_niagara(world,
                "/Game/Art/VFX/Library/Character/Dragons/Generic", "NS_VFX_Dragonfire_Laser",
                {X = ppos.X, Y = ppos.Y, Z = ppos.Z - 1100},
                {Pitch = 0, Yaw = 0, Roll = 90})
            print("[VFX] F6 beam at player Z-1100: " .. (result and "OK" or "FAIL") .. "\n")
        end)
    end)
end)

-- Caps Lock = toggle scoreboard
RegisterKeyBind(Key.CAPS_LOCK, function()
    if not _wilderena_active then return end
    ExecuteInGameThread(function()
        pcall(function()
            local mod_actor = FindFirstOf("ModActor_C")
            if mod_actor and mod_actor:IsValid() then
                local widget = mod_actor.ScoreboardWidget
                if widget and widget:IsValid() then
                    scoreboard_visible = not scoreboard_visible
                    widget.StatsPanel:SetVisibility(scoreboard_visible and 0 or 2)
                end
            end
        end)
    end)
end)

-- ============================================================================
-- PRELOAD
-- ============================================================================
-- Preload powerup assets (synchronous — LoadAsset doesn't need game thread)
print("[WilderenaClient] Running preload synchronously...\n")
local preload_ok, preload_err = pcall(preload_powerup_assets)
if not preload_ok then
    print("[WilderenaClient] Preload ERROR: " .. tostring(preload_err) .. "\n")
end

-- Delayed re-preload (asset pinning deferred to after hooks register — needs valid world)
ExecuteWithDelay(5000, function()
    print("[WilderenaClient] Delayed re-preload firing...\n")
    pcall(preload_powerup_assets)
end)

-- ============================================================================
-- CLASS/GEAR ASSET PRELOAD — warms PSO + keeps assets pinned
-- ============================================================================
-- Every armor/weapon/cape/rune/trinket the server can push. Cold load during
-- gameplay (first T6 preview, first respawn, first mastery pickup) is what
-- trips D3D12 on some GPUs/drivers. Loading them all up front moves the
-- expensive PSO compile into a controlled warmup window.

local _pinned_class_assets = {}  -- keep strong refs so GC never drops these

local G  = "/Game/Gameplay/Character/Player/Equipment"
local D  = "/DowdunReach/Gameplay/Character/Player/Equipment"

local CLASS_PRELOAD_PATHS = {
    -- T2 base kit
    G .. "/Head/ITEM_Armour_T2_Head_Reinforced.ITEM_Armour_T2_Head_Reinforced",
    G .. "/Body/ITEM_Armour_T2_Body_Reinforced.ITEM_Armour_T2_Body_Reinforced",
    G .. "/Legs/ITEM_Armour_T2_Legs_Reinforced.ITEM_Armour_T2_Legs_Reinforced",

    -- Capes
    G .. "/Cape/ITEM_Cape_Adventurers_Red.ITEM_Cape_Adventurers_Red",
    G .. "/Cape/ITEM_Cape_Adventurers_Blue.ITEM_Cape_Adventurers_Blue",
    G .. "/Cape/ITEM_Cape_Trimmed_Skillcape_Attack.ITEM_Cape_Trimmed_Skillcape_Attack",
    G .. "/Cape/ITEM_Cape_Trimmed_Skillcape_Magic.ITEM_Cape_Trimmed_Skillcape_Magic",
    D .. "/Cape/ITEM_Cape_RedDyad.ITEM_Cape_RedDyad",
    D .. "/Cape/ITEM_Cape_RedHex.ITEM_Cape_RedHex",
    D .. "/Cape/ITEM_Cape_BlueDyad.ITEM_Cape_BlueDyad",
    D .. "/Cape/ITEM_Cape_BlueHex.ITEM_Cape_BlueHex",

    -- Held weapons — base + tiered (archer/assassin/guardian/berserker/fire_mage/air_mage T3-T6)
    G .. "/Held/Mace/ITEM_Club_SwingSlash.ITEM_Club_SwingSlash",
    G .. "/Held/Bow/ITEM_Shortbow_Wood.ITEM_Shortbow_Wood",
    G .. "/Held/Torch/ITEM_Torch.ITEM_Torch",
    G .. "/Held/Bow/ITEM_Shortbow_Oak.ITEM_Shortbow_Oak",
    G .. "/Held/Bow/ITEM_Longbow_Oak.ITEM_Longbow_Oak",
    G .. "/Held/Bow/ITEM_Shortbow_Hunter.ITEM_Shortbow_Hunter",
    G .. "/Held/Bow/ITEM_Longbow_Hunter.ITEM_Longbow_Hunter",
    G .. "/Held/Bow/ITEM_Shortbow_Willow.ITEM_Shortbow_Willow",
    G .. "/Held/Bow/ITEM_Longbow_Willow.ITEM_Longbow_Willow",
    D .. "/Held/Bow/ITEM_Shortbow_Maple.ITEM_Shortbow_Maple",
    D .. "/Held/Bow/ITEM_Longbow_Maple.ITEM_Longbow_Maple",
    G .. "/Held/Dagger/ITEM_Dagger_Bronze.ITEM_Dagger_Bronze",
    G .. "/Held/Dagger/ITEM_Dagger_Iron.ITEM_Dagger_Iron",
    G .. "/Held/Dagger/ITEM_Dagger_Steel.ITEM_Dagger_Steel",
    D .. "/Held/Dagger/ITEM_Dagger_Mithril.ITEM_Dagger_Mithril",
    G .. "/Held/Sword/ITEM_Sword_Bronze.ITEM_Sword_Bronze",
    G .. "/Held/Sword/ITEM_Sword_Iron.ITEM_Sword_Iron",
    G .. "/Held/Sword/ITEM_Sword_Steel.ITEM_Sword_Steel",
    D .. "/Held/Sword/ITEM_Sword_Mithril.ITEM_Sword_Mithril",
    G .. "/Held/Shield/ITEM_Shield_Bronze.ITEM_Shield_Bronze",
    G .. "/Held/Shield/ITEM_Shield_Iron.ITEM_Shield_Iron",
    G .. "/Held/Shield/ITEM_Shield_Steel.ITEM_Shield_Steel",
    D .. "/Held/Shield/ITEM_Shield_Mithril.ITEM_Shield_Mithril",
    G .. "/Held/GreatSword/ITEM_GreatSword_Bronze.ITEM_GreatSword_Bronze",
    G .. "/Held/GreatSword/ITEM_GreatSword_Iron.ITEM_GreatSword_Iron",
    G .. "/Held/GreatSword/ITEM_GreatSword_Steel.ITEM_GreatSword_Steel",
    D .. "/Held/GreatSword/ITEM_GreatSword_Mithril.ITEM_GreatSword_Mithril",
    G .. "/Held/Staff/ITEM_Staff_Garou.ITEM_Staff_Garou",
    G .. "/Held/Staff/ITEM_Staff_Battlestaff.ITEM_Staff_Battlestaff",
    G .. "/Held/Staff/ITEM_Staff_Splitbark.ITEM_Staff_Splitbark",
    D .. "/Held/Staff/ITEM_Staff_Maple.ITEM_Staff_Maple",
    G .. "/Held/Staff/ITEM_Staff_Oak.ITEM_Staff_Oak",

    -- Mastery / unique weapons
    G .. "/Held/UniqueWeapons/Shortbow/CrystalBow/ITEM_Shortbow_CrystalBow.ITEM_Shortbow_CrystalBow",
    G .. "/Held/UniqueWeapons/Club/AbyssalWhip/ITEM_Club_AbyssalWhip.ITEM_Club_AbyssalWhip",
    G .. "/Held/Scimitar/ITEM_Scimitar_Imaru.ITEM_Scimitar_Imaru",
    G .. "/Held/Shield/ITEM_Masterworks_Shield_Dragonfire_Imaru.ITEM_Masterworks_Shield_Dragonfire_Imaru",
    D .. "/Held/GreatSword/ITEM_Masterworks_GreatSword_TitansWrath.ITEM_Masterworks_GreatSword_TitansWrath",
    D .. "/Held/Staff/ITEM_Masterwork_Staff_Zamorak.ITEM_Masterwork_Staff_Zamorak",
    G .. "/Held/UniqueWeapons/Staff/StaffOfLight/ITEM_Staff_StaffOfLight.ITEM_Staff_StaffOfLight",

    -- Ammo
    G .. "/Ammo/ITEM_Ammo_Arrows_Bone_Bodkin.ITEM_Ammo_Arrows_Bone_Bodkin",
    G .. "/Ammo/ITEM_Ammo_Arrows_Bronze_Bodkin.ITEM_Ammo_Arrows_Bronze_Bodkin",
    G .. "/Ammo/ITEM_Ammo_Arrows_Iron_Bodkin.ITEM_Ammo_Arrows_Iron_Bodkin",
    G .. "/Ammo/ITEM_Ammo_Arrows_Steel_Bodkin.ITEM_Ammo_Arrows_Steel_Bodkin",
    D .. "/Ammo/ITEM_Ammo_Arrows_Mithril_Bodkin.ITEM_Ammo_Arrows_Mithril_Bodkin",

    -- Runes
    "/Game/Gameplay/Items/Resources/Magic/ITEM_Rune_Air.ITEM_Rune_Air",
    "/Game/Gameplay/Items/Resources/Magic/ITEM_Rune_Fire.ITEM_Rune_Fire",
    "/Game/Gameplay/Items/Resources/Magic/ITEM_Rune_Nature.ITEM_Rune_Nature",
    "/Game/Gameplay/Items/Resources/Magic/ITEM_Rune_Law.ITEM_Rune_Law",
    "/Game/Gameplay/Items/Resources/Magic/ITEM_Rune_Astral.ITEM_Rune_Astral",

    -- Trinkets
    G .. "/Jewellery/ITEM_Trinket_Iconic_Amulet_of_Accuracy.ITEM_Trinket_Iconic_Amulet_of_Accuracy",
    G .. "/Jewellery/ITEM_Trinket_Iconic_Ring_of_Recoil.ITEM_Trinket_Iconic_Ring_of_Recoil",
    G .. "/Jewellery/ITEM_Trinket_Iconic_Amulet_of_Strength.ITEM_Trinket_Iconic_Amulet_of_Strength",
    G .. "/Jewellery/ITEM_Trinket_Iconic_Amulet_of_Magic.ITEM_Trinket_Iconic_Amulet_of_Magic",
    D .. "/Jewellery/ITEM_Trinket_Unholy_Symbol.ITEM_Trinket_Unholy_Symbol",
}

-- T3-T6 armor (head/body/legs) for each class. Generated from the armor(tier, name) helper.
local CLASS_ARMOR_SETS = {
    archer    = {[3]="HardLeather",   [4]="WildArcher",     [5]="Ranger",       [6]="BlackRanger"},
    assassin  = {[3]="HardLeather",   [4]="StuddedLeather", [5]="GreenDragonHide"},
    guardian  = {[3]="Bronze",        [4]="Paladin",        [5]="White",        [6]="Mithril"},
    berserker = {[3]="Bronze",        [4]="Iron",           [5]="Skeleton",     [6]="Black"},
    fire_mage = {[3]="Wizard",        [4]="DragonkinMage",  [5]="Necromancer",  [6]="Zamorak"},
    air_mage  = {[3]="Wizard",        [4]="DarkMage",       [5]="Splitbark",    [6]="Mystic"},
}
for _, set in pairs(CLASS_ARMOR_SETS) do
    for tier, name in pairs(set) do
        table.insert(CLASS_PRELOAD_PATHS, string.format("%s/Head/ITEM_Armour_T%d_Head_%s.ITEM_Armour_T%d_Head_%s", G, tier, name, tier, name))
        table.insert(CLASS_PRELOAD_PATHS, string.format("%s/Body/ITEM_Armour_T%d_Body_%s.ITEM_Armour_T%d_Body_%s", G, tier, name, tier, name))
        table.insert(CLASS_PRELOAD_PATHS, string.format("%s/Legs/ITEM_Armour_T%d_Legs_%s.ITEM_Armour_T%d_Legs_%s", G, tier, name, tier, name))
    end
end
-- Assassin's T6 is BlueDragonhide (under /DowdunReach/)
table.insert(CLASS_PRELOAD_PATHS, D .. "/Head/ITEM_Armour_T6_Head_BlueDragonhide.ITEM_Armour_T6_Head_BlueDragonhide")
table.insert(CLASS_PRELOAD_PATHS, D .. "/Body/ITEM_Armour_T6_Body_BlueDragonHide.ITEM_Armour_T6_Body_BlueDragonHide")
table.insert(CLASS_PRELOAD_PATHS, D .. "/Legs/ITEM_Armour_T6_Legs_BlueDragonhide.ITEM_Armour_T6_Legs_BlueDragonhide")

local function preload_class_assets()
    local total = #CLASS_PRELOAD_PATHS
    local loaded = 0
    local missing = 0
    for _, path in ipairs(CLASS_PRELOAD_PATHS) do
        local obj = nil
        pcall(function() obj = StaticFindObject(path) end)
        if not obj then
            pcall(function() LoadAsset(path:match("^(.-)%..*$") or path) end)
            pcall(function() obj = StaticFindObject(path) end)
        end
        if obj then
            _pinned_class_assets[path] = obj  -- pin against GC
            loaded = loaded + 1
        else
            missing = missing + 1
        end
    end
    print(string.format("[WilderenaClient] Class asset preload: %d/%d loaded (%d missing) — PSO warmup in progress\n",
        loaded, total, missing))
    return loaded, missing
end

-- Run class preload on mod init. Cold PSO compile happens here, not mid-match.
print("[WilderenaClient] Running class/gear preload...\n")
local cp_ok, cp_err = pcall(preload_class_assets)
if not cp_ok then
    print("[WilderenaClient] Class preload ERROR: " .. tostring(cp_err) .. "\n")
end

-- Re-run a few seconds later to catch anything that streamed in late.
ExecuteWithDelay(8000, function()
    pcall(preload_class_assets)
end)

-- ============================================================================
-- LOADED
-- ============================================================================
print("[WilderenaClient] Loaded — event-driven architecture, CapsLock=scoreboard, zero polling loops\n")


-- =============================================================================
-- THE ABYSS FIRE ZONE — proximity-driven activation
-- Fires + ambient loops only run when local player is inside the Abyss.
-- No background load when not in dungeon → eliminates death-window crash race.
-- =============================================================================
local abyss_fire_coords = {
    -- 4 corners + 1 middle (5 big fires, 2 each side + center)
    {X=16750, Y=186600, Z=-2779}, {X=16750, Y=189200, Z=-2779},   -- right side
    {X=13350, Y=186600, Z=-2779}, {X=13350, Y=189200, Z=-2779},   -- left side
    {X=15050, Y=187900, Z=-2779},                                  -- middle
}
local ABYSS_CENTROID = {X=15050, Y=187900, Z=-2379}
-- Abyss is DIRECTLY BELOW the arena → can't use 3D distance (arena shares XY).
-- Gate on Z instead: Abyss floor=-2379, gate dest=-1392, arena=-192.
-- Player below Z_THRESHOLD AND within horizontal radius = inside Abyss.
local ABYSS_Z_THRESHOLD = -1000
local ABYSS_XY_RADIUS_SQ = 6000 * 6000

local _abyss_active = false
local _abyss_fire_comps = {}  -- spawned NiagaraComponents (for despawn)
local _abyss_nia_systems = {}  -- cached system refs (loaded once)

local function _abyss_load_systems()
    if _abyss_nia_systems.big then return true end
    local paths = {
        big = "/Game/Marketplace/Realistic_Pack/Niagara/Fire/NS_Fire_Big_2.NS_Fire_Big_2",
        fs  = "/Game/Art/VFX/Library/Spells/FireSpirit/NS_FireSpirit_Playful.NS_FireSpirit_Playful",
        i1  = "/Game/Art/VFX/Library/Combat/Magic/Fire/Attack_01/NS_Attack_Fire_Magic_01_Impact.NS_Attack_Fire_Magic_01_Impact",
        i2  = "/Game/Art/VFX/Library/Combat/Magic/Fire/Attack_02/NS_Attack_Fire_Magic_02_Impact.NS_Attack_Fire_Magic_02_Impact",
    }
    for _, p in pairs(paths) do pcall(function() LoadAsset(p) end) end
    for k, p in pairs(paths) do _abyss_nia_systems[k] = StaticFindObject(p) end
    local s = {}
    for k, v in pairs(_abyss_nia_systems) do s[k] = (v and v:IsValid()) and "OK" or "MISSING" end
    print("[WilderenaClient] Abyss systems load: big=" .. (s.big or "?") .. " fs=" .. (s.fs or "?") .. " i1=" .. (s.i1 or "?") .. " i2=" .. (s.i2 or "?") .. string.char(10))
    return _abyss_nia_systems.big ~= nil
end

local function _activate_abyss_fires()
    if _abyss_active then return end
    local player = FindFirstOf("BP_PlayerCharacter_C")
    if not player or not player:IsValid() then return end
    local world = player:GetWorld()
    if not world then return end
    local nflib = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
    if not nflib then return end
    if not _abyss_load_systems() then
        print("[WilderenaClient] Abyss Fire Zone: systems NOT loaded (NS_Fire_Big_2 missing) - fires skipped\n")
        return
    end

    local big_sys = _abyss_nia_systems.big
    local count = 0
    _abyss_fire_comps = {}
    for _, c in ipairs(abyss_fire_coords) do
        pcall(function()
            local f = nflib:SpawnSystemAtLocation(world, big_sys, c, {Pitch=0,Yaw=0,Roll=0}, {X=14,Y=14,Z=14}, false, true, 0, false)
            if f then
                count = count + 1
                table.insert(_abyss_fire_comps, f)
            end
        end)
    end
    _abyss_active = true
    print(string.format("[WilderenaClient] Abyss Fire Zone: ACTIVATED (%d/%d fires)\n", count, #abyss_fire_coords))
end

local function _deactivate_abyss_fires()
    if not _abyss_active then return end
    local destroyed = 0
    for _, comp in ipairs(_abyss_fire_comps) do
        pcall(function()
            if comp and comp:IsValid() then
                pcall(function() comp:DeactivateImmediate() end)  -- kill all live particles
                pcall(function() comp:DestroyComponent() end)      -- full removal
                destroyed = destroyed + 1
            end
        end)
    end
    _abyss_fire_comps = {}
    _abyss_active = false
    print(string.format("[WilderenaClient] Abyss Fire Zone: DEACTIVATED (%d destroyed)\n", destroyed))
end

local function _abyss_rand_pos()
    local base = abyss_fire_coords[math.random(#abyss_fire_coords)]
    return {X = base.X + (math.random()-0.5)*400, Y = base.Y + (math.random()-0.5)*400, Z = base.Z + 800 + math.random()*400}
end

-- Ambient loops — started once at module load, gated on _abyss_active
LoopAsync(500, function()
    if _abyss_active then
        ExecuteInGameThread(function()
            pcall(function()
                if not _abyss_active then return end
                local p = FindFirstOf("BP_PlayerCharacter_C")
                if not p or not p:IsValid() then return end
                local w = p:GetWorld()
                if not w then return end
                local nflib = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
                local fs_sys = _abyss_nia_systems.fs
                if not nflib or not fs_sys or not fs_sys:IsValid() then return end
                for _ = 1, 3 do pcall(function() nflib:SpawnSystemAtLocation(w, fs_sys, _abyss_rand_pos(), {Pitch=0,Yaw=0,Roll=0}, {X=1,Y=1,Z=1}, true, true, 0, false) end) end
            end)
        end)
    end
    return false
end)

LoopAsync(2000, function()
    if _abyss_active then
        ExecuteInGameThread(function()
            pcall(function()
                if not _abyss_active then return end
                local p = FindFirstOf("BP_PlayerCharacter_C")
                if not p or not p:IsValid() then return end
                local w = p:GetWorld()
                if not w then return end
                local nflib = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
                local i1 = _abyss_nia_systems.i1
                if nflib and i1 and i1:IsValid() then
                    pcall(function() nflib:SpawnSystemAtLocation(w, i1, _abyss_rand_pos(), {Pitch=0,Yaw=0,Roll=0}, {X=1,Y=1,Z=1}, true, true, 0, false) end)
                end
            end)
        end)
    end
    return false
end)

ExecuteWithDelay(1000, function()
    LoopAsync(2000, function()
        if _abyss_active then
            ExecuteInGameThread(function()
                pcall(function()
                    if not _abyss_active then return end
                    local p = FindFirstOf("BP_PlayerCharacter_C")
                    if not p or not p:IsValid() then return end
                    local w = p:GetWorld()
                    if not w then return end
                    local nflib = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
                    local i2 = _abyss_nia_systems.i2
                    if nflib and i2 and i2:IsValid() then
                        pcall(function() nflib:SpawnSystemAtLocation(w, i2, _abyss_rand_pos(), {Pitch=0,Yaw=0,Roll=0}, {X=1,Y=1,Z=1}, true, true, 0, false) end)
                    end
                end)
            end)
        end
        return false
    end)
end)

-- Proximity poll: every 2s, check if local player is in the Abyss.
-- Z-gated: player must be BELOW arena floor (Z < -1000) AND within XY radius.
-- Arena is directly above Abyss, so 3D distance check would falsely include arena.
-- Also gated on _wilderena_active so we never even poll on offline/non-Wilderena servers.
LoopAsync(1000, function()
    if not _wilderena_active then
        if _abyss_active then ExecuteInGameThread(function() pcall(_deactivate_abyss_fires) end) end
        return false
    end
    ExecuteInGameThread(function()
        pcall(function()
            -- LOCAL player only — FindFirstOf can return a REMOTE pawn in multiplayer,
            -- which made the abyss gate test the wrong player (fires didn't activate for
            -- the 2nd player / appeared delayed). Reuse the local-pawn getter.
            local p = _bb_get_local_pawn() or FindFirstOf("BP_PlayerCharacter_C")
            if not p or not p:IsValid() then return end
            local loc = p:K2_GetActorLocation()
            local in_abyss = false
            if loc.Z < ABYSS_Z_THRESHOLD then
                local dx = loc.X - ABYSS_CENTROID.X
                local dy = loc.Y - ABYSS_CENTROID.Y
                if (dx*dx + dy*dy) < ABYSS_XY_RADIUS_SQ then
                    in_abyss = true
                end
            end
            if in_abyss then
                if not _abyss_active then _activate_abyss_fires() end
            else
                if _abyss_active then _deactivate_abyss_fires() end
            end
        end)
    end)
    return false
end)


-- ============================================================================
-- DUNGEON FX SYSTEM (client, proximity-driven)
--  * Gate marker: a mana-build loop at each dungeon TP-out point (D1=Fire,
--    D2=Nature, D3=Air, x5).
--  * Ambient fog: LocalFogVolume per dungeon -- D2 = swamp, D1/D3 = very light.
--  * D2 entry: ImaruGaze_OnCharacter on the player.
--  * D2 recurring (~1.5s): ImaruGaze_Burst + TowerSealBreak_Door spawned in the
--    band between the Zogre (boss) spawn and the TP gateway.
-- Proximity zones ESTIMATED from each dungeon destination<->boss midpoint
-- (no authored perimeter) -- tune c/rsq/zlo/zhi if fog/markers land wrong.
-- ============================================================================
local function _d2_spawn(world, pkg, pos, scale)   -- scaled niagara spawn (also used by key 6)
    local name = pkg:match("/([^/]+)$")
    local full = pkg .. "." .. name
    local sys = _cached_niagara_sys[name]
    if not sys or not sys:IsValid() then pcall(function() sys = StaticFindObject(full) end) end
    if not sys or not sys:IsValid() then
        pcall(function() LoadAsset(pkg) end)
        pcall(function() sys = StaticFindObject(full) end)
        if sys and sys:IsValid() then _cached_niagara_sys[name] = sys end
    end
    if not sys or not sys:IsValid() then return nil end
    local lib = get_niagara_lib()
    if not lib then return nil end
    local s = scale or 1.0
    return lib:SpawnSystemAtLocation(world, sys, pos, { Pitch = 0, Yaw = 0, Roll = 0 }, { X = s, Y = s, Z = s }, true, true, 0, false)
end

local MANA = "/Game/Art/VFX/Library/Spells/ManaBuild/NS_Mana_Build_Loop_"
local DFX = {
    [1] = { c = {X=16341,Y=186600}, zlo=-2700, zhi=-1000, rsq=3800*3800,
            gate = {X=17640,Y=185280,Z=-1392}, gfx=MANA.."Fire",   gs=2.5, fog="light" },
    [2] = { c = {X=6553,Y=187511},  zlo=-99999, zhi=-2700, rsq=3500*3500,
            gate = {X=8148,Y=185855,Z=-3124},  gfx=MANA.."Nature", gs=2.5, fog="swamp",
            boss = {X=4958,Y=189167,Z=-3516} },
    [3] = { c = {X=10756,Y=180712}, zlo=1000, zhi=99999, rsq=3500*3500,
            gate = {X=12458,Y=178999,Z=1684},  gfx=MANA.."Air",    gs=2.5, fog="light" },
}
local D2_ONCHAR = "/Game/Art/VFX/Library/Env/Fellhollow/Withering/ImaruGaze/NS_VFX_Character_ImaruGaze_OnCharacter"
local D2_BURST  = "/Game/Art/VFX/Library/Env/Fellhollow/Withering/ImaruGaze/NS_VFX_Character_ImaruGaze_Burst"
local D2_SEAL   = "/Game/Art/VFX/Library/Env/Fellhollow/ImaruSeal/NS_VFX_TowerSealBreak_Door"
local D2_FX_SCALE = 2.5
local D2_LOOP_MS = 1500
local FOG_SCALE = { X = 70.0, Y = 70.0, Z = 20.0 }   -- LocalFogVolume coverage (tune)

local _dfx_cur = 0
local _dfx_gate = nil
local _dfx_fog = nil

local function _dfx_spawn_fog(world, d)
    local cls = StaticFindObject("/Script/Engine.LocalFogVolume")
    if not cls then return nil end
    local a = world:SpawnActor(cls, { X = d.c.X, Y = d.c.Y, Z = d.gate.Z }, {})
    if not a or not a:IsValid() then return nil end
    pcall(function() a:SetActorScale3D(FOG_SCALE) end)
    local comp = a.LocalFogVolumeVolume
    if comp and comp:IsValid() then
        if d.fog == "swamp" then
            pcall(function() comp:SetHeightFogExtinction(3.0) end)
            pcall(function() comp:SetHeightFogFalloff(0.5) end)
            pcall(function() comp:SetFogAlbedo({ R = 0.42, G = 0.5, B = 0.4, A = 1.0 }) end)
        else
            pcall(function() comp:SetHeightFogExtinction(0.4) end)
            pcall(function() comp:SetHeightFogFalloff(0.8) end)
            pcall(function() comp:SetFogAlbedo({ R = 0.7, G = 0.72, B = 0.78, A = 1.0 }) end)
        end
    end
    return a
end

local function _dfx_clear()
    if _dfx_gate and _dfx_gate:IsValid() then
        pcall(function() _dfx_gate:DeactivateImmediate() end)
        pcall(function() _dfx_gate:DestroyComponent() end)
    end
    if _dfx_fog and _dfx_fog:IsValid() then pcall(function() _dfx_fog:K2_DestroyActor() end) end
    _dfx_gate = nil
    _dfx_fog = nil
end

LoopAsync(D2_LOOP_MS, function()
    if _dfx_cur == 2 then
        ExecuteInGameThread(function()
            pcall(function()
                local d = DFX[2]
                local p = _bb_get_local_pawn() or FindFirstOf("BP_PlayerCharacter_C")
                if not p or not p:IsValid() then return end
                local w = p:GetWorld()
                local g, b = d.gate, d.boss
                local function pt()
                    local t = math.random()
                    return { X = b.X + (g.X - b.X) * t + (math.random()-0.5)*400,
                             Y = b.Y + (g.Y - b.Y) * t + (math.random()-0.5)*400,
                             Z = b.Z + (g.Z - b.Z) * t + 100 }
                end
                _d2_spawn(w, D2_BURST, pt(), D2_FX_SCALE)
                _d2_spawn(w, D2_SEAL,  pt(), D2_FX_SCALE)
            end)
        end)
    end
    return false
end)

LoopAsync(1000, function()
    if not _wilderena_active then
        if _dfx_cur ~= 0 then ExecuteInGameThread(function() pcall(_dfx_clear) end); _dfx_cur = 0 end
        return false
    end
    ExecuteInGameThread(function()
        pcall(function()
            local p = _bb_get_local_pawn() or FindFirstOf("BP_PlayerCharacter_C")
            if not p or not p:IsValid() then return end
            local loc = p:K2_GetActorLocation()
            local now = 0
            for n, d in pairs(DFX) do
                if loc.Z > d.zlo and loc.Z < d.zhi then
                    local dx = loc.X - d.c.X
                    local dy = loc.Y - d.c.Y
                    if (dx * dx + dy * dy) < d.rsq then now = n; break end
                end
            end
            if now ~= _dfx_cur then
                _dfx_clear()
                _dfx_cur = now
                if now ~= 0 then
                    local d = DFX[now]
                    local w = p:GetWorld()
                    _dfx_gate = _d2_spawn(w, d.gfx, d.gate, d.gs)
                    _dfx_fog = _dfx_spawn_fog(w, d)
                    if now == 2 then _d2_spawn(w, D2_ONCHAR, p:K2_GetActorLocation(), D2_FX_SCALE) end
                    print("[WilderenaClient] Dungeon FX: ENTER dungeon " .. now .. " (fog=" .. d.fog .. ")" .. string.char(10))
                else
                    print("[WilderenaClient] Dungeon FX: EXIT" .. string.char(10))
                end
            end
        end)
    end)
    return false
end)

-- ============================================================================
-- KEY 6: scaled VFX cycler (mana-build colours x2 + big fire x6)
-- Each press spawns the next at the player with its scale. Reuses _d2_spawn.
-- ============================================================================
local _k6_list = {
    { p = "/Game/Art/VFX/Library/Spells/ManaBuild/NS_Mana_Build_Loop_Fire",   s = 5.0 },
    { p = "/Game/Art/VFX/Library/Spells/ManaBuild/NS_Mana_Build_Loop_Nature", s = 5.0 },
    { p = "/Game/Art/VFX/Library/Spells/ManaBuild/NS_Mana_Build_Loop_Air",    s = 5.0 },
    { p = "/Game/Marketplace/Realistic_Pack/Niagara/Fire/NS_Fire_Big_2",      s = 14.0 },
    { p = "/Game/Art/VFX/Library/AbyssalDemonFX/Export/AbyssalOrb/NS_AbyssalDemon_Orb",            s = 1.0 },
    { p = "/Game/Art/VFX/Library/AbyssalDemonFX/Export/AbyssalOrb/NS_AbyssalDemon_Orb_EnergyLoop", s = 1.0 },
    { p = "/Game/Art/VFX/Library/Item/NS_VaultCore_EnergyOut",                s = 1.0 },
    { p = "/Game/Art/VFX/Library/Spells/Surge/NS_Surge_Core",                 s = 1.0 },
    { p = "/Game/Art/VFX/Library/Combat/Magic/Air/NS_Magic_Air_Secondary_Charge_Sphere", s = 1.0 },
}
local _k6_idx = 0
RegisterKeyBind(Key.SIX, function()
    ExecuteInGameThread(function()
        pcall(function()
            _k6_idx = (_k6_idx % #_k6_list) + 1
            local e = _k6_list[_k6_idx]
            local p = _bb_get_local_pawn() or FindFirstOf("BP_PlayerCharacter_C")
            if not p or not p:IsValid() then return end
            local w = p:GetWorld()
            local pos = p:K2_GetActorLocation()
            local comp = _d2_spawn(w, e.p, { X = pos.X, Y = pos.Y, Z = pos.Z + 50 }, e.s)
            print("[K6 VFX] " .. _k6_idx .. "/" .. #_k6_list .. " " .. e.p:match("/([^/]+)$") .. " x" .. e.s .. " -> " .. (comp and "OK" or "FAIL") .. string.char(10))
        end)
    end)
end)
