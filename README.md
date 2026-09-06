# Gen 3 Inspired UI Overhaul — v3.0.0

A full presentation overhaul for Gen1Recomp, rebuilding the Gen I and Gen II interface around a cohesive Gen 3-inspired visual language while keeping the games' native logic, callbacks, battle rules, save data and progression authoritative.

## Install

Install the zip through the Gen1Recomp launcher, or place the `gen3_battle_ui` folder in the launcher `mods/` directory. The mod ID remains `gen3_battle_ui`, so existing settings continue to follow the same install.

Disable `colosseum_ui_overhaul` while using this mod because both mods intentionally own many of the same presentation surfaces.

## v3.0.0 release / hard native-battle-UI guarantee

Version 3.0.0 promotes the cleaned v2.1.38 codebase and makes `HIDE NATIVE BATTLE UI` a true master battle-presentation contract. While that option is ON, the mod now forces its replacement battle presentation even if the separate BATTLE UI, DIALOGUE, POKéMON MENU, BAG, LEVEL-UP, MOVE DELETER, or SERVICE/EVENT presentation toggles are individually OFF. Native gameplay state and input still run; only original battle UI pixels are prevented from reaching the frame.

The hard-hide decision also takes precedence over full-frame battle-world provider deferral. CBE, Stadium-style renderers, Battle Art, Dramaless/Dramatic Shape, vanilla battle environments, and future providers can continue to own their world/actors/camera, but none of them can cause Gen1Recomp's original HUD, command/move boxes, battle dialogue, Yes/No prompts, stat box, move-forget UI, or battle-opened Party/Bag/Summary chrome to reappear while hard hide is active. The provider-facing `uiOwnership` contract is now API v3 and exposes `hardHideNativeBattleUi(state)`.

Before packaging, the complete mod entry was executed in a Lua runtime-integration harness for both Gen I and Gen II. The harness exercised hard hide with the normal BATTLE UI and related sub-toggles deliberately OFF, with and without an active full-frame battle renderer, with Battle Art and Dramaless-style compatibility hooks present, through pushed battle TextBox/ChoiceBox/Party/Bag/MoveLearn/StatBox/MoveDeleter states, and through 750 repeated battle-draw frames per generation. A negative control then disabled hard hide and confirmed the native fallback returns normally. See `VALIDATION_3.0.0.md` for the exact scope and results.

The mod is presentation-only. Pokémon artwork is resolved through the active Gen1Recomp/mod sprite pipeline rather than replaced by a private sprite source, so Battle Arts, ROM sprites and compatible custom sprite packs can remain authoritative. The same resolved sprite source is reused across battle, Party, Summary, PC and Pokédex where possible.

When **Battle UI** is enabled, the mod owns battle interface presentation completely: native command/status HUD chrome is suppressed while the battlefield and externally supplied Pokémon artwork remain available to compatible renderer/sprite mods.

## Notes

- Supports Gen I and Gen II.
- Launcher API: 2.
- Conflicts with `colosseum_ui_overhaul`.
- Gameplay mechanics are not intentionally changed by this mod.
