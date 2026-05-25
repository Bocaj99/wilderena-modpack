# Wilderena VFX Effects Catalog

## ACTIVE — Assigned to gameplay events

### 1. NS_Teleport_Out — Initial Spawn & Random Respawn
- Path: `/Game/Art/VFX/Library/Survival/Magic/Lodestone_Teleport/NS_Teleport_Out`
- Trigger: Player initial spawn into arena + random respawn after death during match
- Spawn at: Player position

### 2. NS_SkillLevelUp_v02 — PvP Kill
- Path: `/Game/Art/VFX/Library/Character/NS_SkillLevelUp_v02`
- Trigger: When a player kills another player
- Spawn at: Killer's position

### 3. NS_VFX_VinesSpawn — Powerup Pickup
- Path: `/Game/Art/VFX/Library/Character/Imaru/BossFight/SpectralVines/NS_VFX_VinesSpawn`
- Trigger: When player grabs a powerup orb (in addition to existing potion consumption loop)
- Spawn at: Player position

### 4. PlayRespawnVFX — Weapon/Armour Upgrade
- Called via: `player:PlayRespawnVFX()` (server-side)
- Trigger: When player receives weapon/armour upgrade during match

### 5. PlayDespawnVFX + DissolveTeleport — Flag Capture Transition
- Called via: `player:PlayDespawnVFX()` then 1s later `player:DissolveTeleport()` (server-side)
- Trigger: When player captures/submits flag, transitioning class

### 6. BP_PlayTeleportEndVFXOnPlayer — Class Preview
- Called via: `player:BP_PlayTeleportEndVFXOnPlayer()` (server-side)
- Trigger: When player tries on a class at lodestone in class/team lobby

### 7. Teleport Out Effect — Team→Class Lobby Transition
- Called via: `player:BP_PlayTeleportBeginVFXOnPlayer()` or `DissolveTeleport` (server-side)
- Trigger: When player teleports from team lodestone to class lobby
- Same effect as initial spawn/random respawn teleport

### 8. NS_Windstep_Launch — Flag/Torch Capture Success
- Path: `/Game/Art/VFX/Library/Spells/Windstep/NS_Windstep_Launch`
- Trigger: When a team successfully captures a flag/torch
- Spawn at: Capturing player position

### 5. NS_Magic_Fire_Cast — Flag Pickup
- Path: `/Game/Art/VFX/Library/Combat/Magic/Fire/NS_Magic_Fire_Cast`
- Trigger: When any player picks up a flag
- Spawn at: Flag position

### 5. NS_VFX_Dragonfire_Laser — Flag Post Beam
- Path: `/Game/Art/VFX/Library/Character/Dragons/Generic/NS_VFX_Dragonfire_Laser`
- Config: Red (Roll=94.2, Pitch=-1.3, Z=playerZ-1100), Blue (Roll=94.25, Pitch=0.2, Z=playerZ-220)
- Trigger: Persistent while flag is at base, despawn on pickup, respawn every 8s

---

## AVAILABLE — Character Status Effects (attached/looping)

### Damage/Combat
- `NS_PlayerCharacter_OnFire_Digi1` — Player on fire (burning dissolve)
- `NS_Character_Bleed` — Bleeding effect
- `NS_Character_Poison` — Poison effect (+ InitialBurst variant)
- `NS_Character_Shocked` — Shock/electric effect
- `NS_Character_Cold` — Cold/freeze effect
- `NS_Character_Toxified` — Toxified effect (+ InitialBurst variant)
- `NS_Character_Wither_Loop` — Wither loop (+ Burst variant)

### Movement/Spells
- `NS_Surge_Out` — Surge dash exit
- `NS_SurgeTrail_A` — Surge trail behind player
- `NS_Surge_Magic_A` — Magic surge effect
- `NS_Surge_Burst` — Surge burst
- `NS_Windstep_Launch` — Windstep jump launch
- `NS_Windstep_Slowfall_Looping` — Windstep slow fall (looping)

### Weapon Enchants
- `NS_EnchantWeapon_Fire` — Fire weapon enchant glow
- `NS_EnchantWeapon_Wind` — Wind weapon enchant glow

### Death/Spawn
- `NS_CharacterRespawn` — Respawn flash effect
- `NS_CharacterDespawn` — Despawn dissolve effect
- `NS_Character_Despawn_AI` — AI despawn effect

### Buffs/Heals
- `NS_Beast_Druid_GarouPride_Heal_Looping` — Heal loop aura
- `NS_MagicFocus_Special` — Magic focus special effect
- `NS_Mana_Build_Loop_Astral` — Astral mana build (looping)

### Combat Abilities
- `NS_VFX_Imaru_Shield_Pulse` — Shield pulse wave
- `NS_VFX_ImaruShield_Special_Parry` — Shield parry flash
- `NS_HunterSense_Shockwave_On` — Hunter sense pulse on
- `NS_HunterSense_Shockwave_Off` — Hunter sense pulse off
- `NS_PoisonParry_Cast` — Poison parry cast
- `NS_PoisonParry_AoE` — Poison parry area effect
- `NS_SpawnProyectiles_FromSky` — Fire projectiles from sky

### Snare/CC
- `NS_Snare_Begins` — Snare start
- `NS_Snare_AI_Loop` — Snare loop
- `NS_Snare_Ends` — Snare end

### Corruption
- `NS_CorruptionShot_Corrupted` — Corruption shot
- `NS_CorruptionArrows_Bow` — Corruption bow glow
- `NS_CorruptionArrows_Head` — Corruption arrow head
- `NS_CorruptionArrows_Trail` — Corruption arrow trail

### Confusion
- `NS_Confuse_Begins` — Confuse start
- `NS_Confuse_Ends` — Confuse end

---

## CHARACTER ANIMATION EFFECTS (Blueprint, not Niagara)

### All BP_PlayerCharacter VFX Functions
These are called directly on the player actor: `player:FunctionName()`

| Function | Description |
|----------|-------------|
| `PlayRespawnVFX` | Dissolve materialize in |
| `PlayDespawnVFX` | Dissolve fade out |
| `DissolveTeleport` | Full dissolve teleport sequence |
| `BP_PlayTeleportBeginVFXOnPlayer` | Teleport start effect |
| `BP_PlayTeleportEndVFXOnPlayer` | Teleport end effect |
| `OnPlayerDeath` | Death sequence |
| `OnPlayerRespawn` | Full respawn (position + dissolve) |
| `OnHealthPotionConsume` | Potion drinking FX start |
| `PotionFXDeactivate` | Potion FX stop |
| `BP_OnSkillLevelUp` | Skill level up celebration |
| `HandleOnEnteredCriticalSurvivalState` | Low HP critical effect |
| `HandleOnExitedCriticalSurvivalState` | HP recovered effect |

---

## Test Keys (WilderenaClient)
- **Numpad 1** = Cycle through character VFX at player position
- **Numpad 0** = Scan nearby interactable actors
- **F3** = Spawn flag post package (torch + beam)
- **F4** = Clear all VFX
- **F5** = Record position
- **F8** = Spawn powerup stacks

---

## FIRE VFX CATALOG (51 discovered via F11 probe, 2026-04-24)

Full list of loaded NiagaraSystem matching fire/flame/burn/ember:

| # | Name | Path |
|---|------|------|
| 1 | NS_Attack_Magic_Fire_01_Projectile | /Game/Art/VFX/Library/Combat/Magic/Fire/Attack_01 |
| 2 | NS_Attack_Magic_Fire_02_Projectile | /Game/Art/VFX/Library/Combat/Magic/Fire/Attack_02 |
| 3 | NS_Magic_Fire_Slash | /Game/Art/VFX/Library/Combat/Magic/Fire |
| 4 | NS_Attack_Fire_SmokeGround_04 | /Game/Art/VFX/Library/Combat/Magic/Fire/Attack_04 |
| 5 | NS_Attack_Magic_Fire_Trail_Proyectiles | /Game/Art/VFX/Library/Combat/Magic/Fire |
| 6 | NS_Magic_Fire_Cast | /Game/Art/VFX/Library/Combat/Magic/Fire |
| 7 | NS_Attack_Fire_Magic_Charge_Staff_Short | /Game/Art/VFX/Library/Combat/Magic/Fire |
| **8** ★ | **NS_Magic_Secondary_Fire_Cast** | /Game/Art/VFX/Library/Combat/Magic/Fire/Attack_Secondary |
| **9** ★ | **NS_Attack_Fire_Magic_Charge_Staff_Looping** | /Game/Art/VFX/Library/Combat/Magic/Fire |
| 10 | NS_SpawnProyectiles_FromSky | /Game/Art/VFX/Library/Combat/Magic/Fire/Attack_04 |
| **11** ★ | **NS_Attack_Fire_Magic_02_Impact** | /Game/Art/VFX/Library/Combat/Magic/Fire/Attack_02 |
| **12** ★ | **NS_Attack_Fire_Magic_01_Impact** | /Game/Art/VFX/Library/Combat/Magic/Fire/Attack_01 |
| 13 | NS_Attack_Fire_Magic_03_AoE | /Game/Art/VFX/Library/Combat/Magic/Fire/Attack_03 |
| 14 | NS_Attack_Magic_Fire_04_AoE | /Game/Art/VFX/Library/Combat/Magic/Fire/Attack_04 |
| 15 | NS_Attack_Fire_Magic_Cast | /Game/Art/VFX/Library/Combat/Magic/Fire |
| 16 | NS_PlayerCharacter_OnFire_Digi1 | /Game/Art/VFX/Library/Character/StatusEffect/OnFire |
| **17** ★ | **NS_Attack_Fire_Magic_BurningGround** | /Game/Art/VFX/Library/Combat/Magic/Fire |
| 18 | NS_Attack_Magic_Fire_Secondary_FlameJet | /Game/Art/VFX/Library/Combat/Magic/Fire/Attack_Secondary |
| 19 | NS_EnchantWeapon_Fire | /Game/Art/VFX/Library/Spells/EnchantWeapon |
| 20 | NS_AbyssalDemon_OnFire_Digi1 | /Game/Art/VFX/Library/Character/StatusEffect/AbyssalDemon |
| 21 | NS_DragonVelgar_OnFire_Digi1 | /Game/Art/VFX/Library/Character/StatusEffect/Velgar |
| 22 | NS_Fire_Small_Burst | /Game/Art/VFX/Library/Survival/Burning |
| **23** ★ | **NS_Campfire_Superheat** | /Game/Art/VFX/Library/Spells/Superheat |
| 24 | NS_CharcoalKiln_Flames_Small | /Game/Art/VFX/Library/Crafting/CharcoalKiln |
| 25 | NS_Smelter_Flames_Medium | /Game/Art/VFX/Library/Crafting/Smelter |
| 26 | NS_Fire_Small | /Game/Art/VFX/Library/Survival/Burning |
| 27 | NS_Smelter_Flames | /Game/Art/VFX/Library/Crafting/Smelter |
| 28 | NS_CookingBench_Flames_A | /Game/Art/VFX/Library/Crafting/Cooker |
| 29 | NS_CharcoalKiln_Flames | /Game/Art/VFX/Library/Crafting/CharcoalKiln |
| 30 | NS_CookingBench_Flames_B | /Game/Art/VFX/Library/Crafting/Cooker |
| **31** ★ | **NS_Furnace_Flames** | /Game/Art/VFX/Library/Crafting/Furnace |
| 32 | NS_ZamorakFlames_AoE | /DowdunReach/Art/VFX/Enemies/Zam_Mage/ZamorakFlames |
| 33 | NS_ZamorakFlames_Player_AoE | /DowdunReach/Art/VFX/Library/Combat/Ranged/ZamorakStaff |
| 34 | NS_Attack_ZamorakMage_Charge_Staff_Looping | /DowdunReach/Art/VFX/Enemies/Zam_Mage/ZamorakFlames/Charge |
| 35 | NS_VFX_Dragonfire_Laser | /Game/Art/VFX/Library/Character/Dragons/Generic |
| **36** ★ | **NS_Mana_Build_Loop_Fire** | /Game/Art/VFX/Library/Spells/ManaBuild |
| 37 | NS_PlayerCharacter_OnFire_FireSpirit | /Game/Art/VFX/Library/Spells/FireSpirit |
| 38 | NS_Attack_Fire_Magic_Staff_Ignite | /Game/Art/VFX/Library/Combat/Magic/Fire |
| **39** ★ | **NS_FireSpirit_Playful** | /Game/Art/VFX/Library/Spells/FireSpirit |
| 40 | NS_FireSpirit_Dies | /Game/Art/VFX/Library/Spells/FireSpirit |
| 41 | NS_FireSpirit | /Game/Art/VFX/Library/Spells/FireSpirit |
| 42 | NS_Fire_Small_Dragonkin | /Game/Art/VFX/Library/Survival/Burning |
| 43 | NS_Anima_Siphon_Fire | /Game/Art/VFX/Library/Env/AnimaVent/Fire |
| 44 | NS_Anima_Loop_Fire | /Game/Art/VFX/Library/Env/AnimaVent/Fire |
| **45** ★ | **NS_Ground_Loop_Fire** | /Game/Art/VFX/Library/Env/AnimaVent/Fire |
| 46 | NS_Hit_Fire | /DowdunReach/Art/VFX/Enemies/Hit_Effects |
| 47 | NS_Env_Torch_01 | /Game/Art/VFX/Library/Survival/Burning |
| 48 | NS_Fireflies_GF | /Game/Art/VFX/Library/Env/Insects/Fireflies |
| 49 | NS_Fireflies_02 | /Game/Art/VFX/Library/Env/Insects/Fireflies |
| **50** ★★ | **NS_Fire_Big_2** (BIG FIRE) | /Game/Marketplace/Realistic_Pack/Niagara/Fire |
| 51 | NS_Fire_Small_NPC | /Game/Art/VFX/Library/Survival/Burning |

★ = selected for gameplay wiring (2026-04-24)
★★ = primary "big fire" pick for dungeon placement

