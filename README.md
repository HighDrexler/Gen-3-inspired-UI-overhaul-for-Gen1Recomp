# Gen 3 Inspired UI Overhaul — v2.0.0

A full presentation overhaul for Gen1Recomp, rebuilding the Gen I and Gen II interface around a cohesive Gen 3-inspired visual language while keeping the games' native logic, callbacks, battle rules, save data and progression authoritative.

## Install

Install the zip through the Gen1Recomp launcher, or place the `gen3_battle_ui` folder in the launcher `mods/` directory. The mod ID remains `gen3_battle_ui`, so existing settings continue to follow the same install.

Disable `colosseum_ui_overhaul` while using this mod because both mods intentionally own many of the same presentation surfaces.

## Major coverage

- Gen I + Gen II battle HUDs, command/move selection, battle dialogue, trainer switching, party indicators and level-up presentation
- Pokémon/Party, Summary, Move Manager, TM/HM teaching, starter selection and naming/nickname flows
- Pokédex, encounter/location data, PC/storage, item storage, Bag, PokéMart and service menus
- Save, Start, Options/UI settings, Mod Manager, Trainer Card/badges and Pokégear
- Unified overworld dialogue, location banners and wide-screen menu presentation
- User-selectable primary/secondary UI colors plus font style, size, weight, character spacing, line spacing, dialogue scale and border controls

## Compatibility priorities

The mod is presentation-only. Pokémon artwork is resolved through the active Gen1Recomp/mod sprite pipeline rather than replaced by a private sprite source, so Battle Arts, ROM sprites and compatible custom sprite packs can remain authoritative. The same resolved sprite source is reused across battle, Party, Summary, PC and Pokédex where possible.

When **Battle UI** is enabled, the mod owns battle interface presentation completely: native command/status HUD chrome is suppressed while the battlefield and externally supplied Pokémon artwork remain available to compatible renderer/sprite mods.

## Notes

- Supports Gen I and Gen II.
- Launcher API: 2.
- Conflicts with `colosseum_ui_overhaul`.
- Gameplay mechanics are not intentionally changed by this mod.
