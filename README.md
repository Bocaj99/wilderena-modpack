# Wilderena — Modpack

Client modpack for **Wilderena**, a 3v3 Capture-the-Flag PvP mode for
*RuneScape: Dragonwilds*. Install this, then join the Wilderena server.

> This repo contains **only client-side code** — the VFX/UI receiver that runs on
> your machine. All game logic runs server-side and is not distributed.

## What's new

- **v1.0.3** — Camera snaps when you join a class lobby (faces outward), spawn into the arena (faces the enemy), and enter a dungeon (faces the boss).
- **v1.0.2** — Fixed the Abyss dungeon fire VFX not rendering for the 2nd player (now lights up per-player, faster).
- **v1.0.1** — Build menu disabled during play (admins toggle with `!builder`).

*Server-side changes (live for everyone automatically — no download needed):* mob loot drops disabled · 2× larger mob weak-points (easier headshots) · 2× larger bosses · per-class runes fixed (no cross-element runes) · archer arrows upgrade with weapon tier · buildings auto-repair.

## Install (easy — full modpack)

1. Download **`WilderenaModpack.zip`** from the [latest Release](../../releases/latest).
2. **Close RuneScape: Dragonwilds** if it's running.
3. Unzip it. Inside you'll find a `payload/` folder with two parts:
   - `payload/game/` → copy its contents into your game install folder
     (the one containing `Binaries\` and `Content\`):
     `…\Steam\steamapps\common\RSDragonwilds\RSDragonwilds\`
   - `payload/appdata/` → copy its contents into
     `%LOCALAPPDATA%\RSDragonwilds\`
4. Launch the game. UE4SS loads automatically (via the bundled `dwmapi.dll` proxy)
   and the **WilderenaClient** mod starts.
5. Join the **Wilderena** server. That's it.

### What's in the modpack
- **UE4SS** runtime + required VC++ runtime DLLs
- Stock UE4SS mods (BPModLoader, ConsoleCommands, Keybinds, UEHelpers)
- **WilderenaClient** — the Wilderena client mod (VFX + UI)
- **CTFScoreboard** LogicMod pak (the in-arena scoreboard)

## What's in this repo (source)
- `client/WilderenaClient/` — the client mod source (`main.lua`, VFX catalog).
  Binaries (DLLs, `.pak`/`.ucas`/`.utoc`) are **not** committed — they ship in the
  Release zip.

## Troubleshooting
- **Game won't start / no mods:** make sure `dwmapi.dll` landed next to the game's
  `RSDragonwilds-Win64-Shipping.exe` in `…\Binaries\Win64\`.
- **No scoreboard:** confirm `CTFScoreboard.pak/.ucas/.utoc` are in
  `…\Content\Paks\LogicMods\`.
- **Copy fails:** the game (or its launcher) is still running — close it fully first.

## Links
- Site / leaderboard: https://github.com/Bocaj99/wilderena-web
