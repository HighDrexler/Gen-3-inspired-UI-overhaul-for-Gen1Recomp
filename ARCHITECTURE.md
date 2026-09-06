# Architecture / Maintenance Contract

## Core rule

The Gen 3 Inspired UI Overhaul is presentation-first. It should replace presentation without becoming the owner of gameplay state.

## Engine-owned behavior

Keep these native whenever possible:

- battle state and turn progression
- Pokémon data and party/storage state
- move learning and TM/HM application
- evolution state
- Move Manager semantics
- Bag item identity and item-use callbacks
- Pokégear map state/cursor behavior
- user settings owned by other mods

## Sprite ownership

The UI should display the currently resolved Pokémon sprite source. It must not silently replace Battle Arts, Crystal/personal sprites or other configured sprite providers.

Portrait ownership is resolved live in this order: an explicit non-ROM `pokemon.sprite` provider, Battle Art's selected interface frame, then the engine/ROM fallback. Party rows, selected Party/Summary cards, PC, and Pokédex share this resolver.

## UI-owned behavior

The mod may own layout, borders, typography, menu presentation, responsive scaling, presentation toggles, battle HUD positioning and other visual composition.

## Gen 1 / Gen 2 compatibility

Gen 1 and Gen 2 do not always share the same native renderer or menu state. Prefer generation-specific adapters around a common visual language rather than forcing one generation's state assumptions onto the other.

Current Gen1Recomp's `Gen2MenuFade` remains responsible for stack completion callbacks, but its white reload sheet is transparent and its hold completes immediately while a replacement menu is enabled.


## Hard native battle UI invariant

`HIDE NATIVE BATTLE UI` is a master battle-surface safety contract. When it is enabled and a live BattleState exists, no original Gen1Recomp battle HUD, command/move box, battle dialogue/choice box, level-up/stat card, move-forget screen, or battle-opened native Party/Bag/Summary chrome may reach the frame. This rule takes precedence over full-frame world-provider deferral. External renderers may own the battlefield, camera, trainers and Pokémon presentation, but they never receive implicit permission to restore native battle chrome.

The implementation must preserve engine lifecycle/state even while suppressing pixels. Prefer visibility predicates and late custom composition; when a native draw performs required per-frame work, execute it under `runDrawInvisible` (zero-area scissor) instead of skipping the call. Hard hide also forces the corresponding existing custom battle auxiliary presentation even if its ordinary per-screen aesthetic toggle is OFF, so the guarantee cannot create a blank or unusable flow. Outside battle, all per-screen toggles remain independent.

`mod.exports.uiOwnership` API v3 exposes `hardHideNativeBattleUi(state)` for compatible providers. This is distinct from ordinary `ownsBattleUi`: the hard-hide query is explicit and should be honored regardless of who owns the world frame.

## Battle environment composition

A hanging menu opened from battle must never substitute the overworld for the active battle surface. On Gen 2, top-level widescreen UI overlays should proxy the live underlying `BattleState:drawWidescreen()` once and then draw their UI over it. Battle environments remain authoritative through the normal BattleState seam; UI code should not hard-code CBE, Stadium, or another provider merely to preserve the background. The literal `bgMode() == "world"` contract is reserved for cases that intentionally want Gen1Recomp to draw the overworld map.

## Performance / cache rule

Cache only values whose invalidation boundary is explicit. Immutable engine-module handles may live for the process; UI option/derived-layout caches are invalidated by this mod's option-change paths; loaded-mod handles are refreshed on loader/battle boundaries. Provider `status()` and `presentationOwnership()` results remain live and must not be memoized across frames, because external battle renderers can change ownership during a battle. Window-dependent geometry must include the current dimensions and relevant UI settings in its cache key.

## Native fallbacks

When a native subsystem is tightly coupled to state and a custom renderer is not yet complete, a functional native fallback is preferred over a visually consistent but broken replacement. The Gen 2 Pokégear MAP is an intentional example in v1.4.1.

## Future refactor direction

The 3.0.0 source remains behavior-compatible with the established Gen I/Gen II feature surface and external-provider contracts. Future cleanup should gradually separate battle presentation, shared drawing helpers, Gen 1 menu adapters, Gen 2 menu adapters, settings, sprite resolution and compatibility shims into smaller modules while preserving the stable public mod ID and manifest contract.
