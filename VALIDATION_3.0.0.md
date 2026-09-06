# Gen 3 Inspired UI Overhaul 3.0.0 — Final Runtime / Hard-Hide Validation

## Release gate

3.0.0 is built from the cleaned 2.1.38 baseline. The release gate for this pass was the `HIDE NATIVE BATTLE UI` option: while that option is enabled, original Gen1Recomp battle UI must not become visible because another battle renderer is active, because a subordinate UI toggle is off, or because a pushed battle menu temporarily owns the top of the state stack.

## Executed runtime-integration test

The complete 3.0.0 `main.lua` entry chunk was loaded and initialized under executable Lua for **both Gen I and Gen II**. The harness instantiates live stack states, invokes the mod's real installers/hooks/wrappers, instruments native draw calls, and uses the current Gen1Recomp battle draw contracts for the native HUD visibility boundaries. This is an execution test, not a static grep-only test.

The hard-hide test intentionally set all of the following OFF except the master hide itself:

- `revampedBattleUI = false`
- `revampedDialogueBoxes = false`
- `revampedPokemonMenu = false`
- `revampedOverworldMenus = false`
- `revampedLevelUpUI = false`
- `revampedMoveDeleterUI = false`
- `revampedServiceMenusUI = false`
- `hideNativeBattleUI = true`

That configuration is deliberately harsher than normal user settings: it proves hard hide is a master guarantee rather than accidentally depending on another presentation toggle.

### Gen I result

PASS:

- launcher `battle.bottom_ui_visible` reports hidden;
- launcher `battle.status_hud_visible` reports hidden;
- direct native `drawHUDs` pixels are suppressed while its lifecycle still executes;
- direct native `drawTextArea` pixels are suppressed while its lifecycle still executes;
- Dramaless/Dramatic-style `snapHUDs` / `drawHudPanels` compatibility cannot reintroduce native HUD chrome;
- Battle Art's official suppress hook receives hard suppression;
- battle TextBox and ChoiceBox remain custom with the normal dialogue toggle OFF;
- battle Party remains custom with the normal Pokémon-menu toggle OFF;
- battle Bag remains non-native with the normal overworld-menu toggle OFF;
- battle MoveLearn remains non-native with the normal Pokémon-menu toggle OFF;
- level-up StatBox remains both hidden natively **and** usable through the modern stat card with the level-up toggle OFF;
- the late HUD pass still renders replacement UI while ordinary `BATTLE UI` is OFF.

Endurance pass:

`GEN1_STRESS_750_NO_NATIVE_UI_OK lifecycleClipped=1500`

750 consecutive frame-equivalent draws of both native HUD and native text seams produced zero visible native UI pixels while 1,500 underlying lifecycle draws still executed under the zero-area scissor.

### Gen II result

PASS:

- launcher `battle.bottom_ui_visible` reports hidden;
- launcher `battle.status_hud_visible` reports hidden;
- with an active full-frame world renderer, `BattleState:drawPanel()` still executes for lifecycle but all of its native pixels are scissor-suppressed;
- native stat-box pixels are suppressed;
- battle TextBox and ChoiceBox remain custom with dialogue OFF;
- the standalone Gen II MoveDeleter is still claimed while both MOVE DELETER UI and SERVICE/EVENT MENUS are OFF;
- the late HUD pass still renders replacement UI while ordinary `BATTLE UI` is OFF;
- when the full-frame renderer is removed, native battler picture **content** is preserved for the vanilla battle environment while native status HUD and bottom command/dialogue UI remain hidden.

Endurance passes:

`GEN2_PROVIDER_STRESS_750_NO_NATIVE_UI_OK lifecycleClipped=750`

`GEN2_VANILLA_STRESS_750_UI_HIDDEN_CONTENT_PRESERVED_OK battlerPics=750`

The first pass validates 750 frames under an active CBE/Stadium-style full-frame provider. The second validates 750 frames with the vanilla environment: all 750 native battler-picture content draws remain available, while original status/bottom UI draws remain at zero.

### Negative control

After each generation's hard-hide tests, the harness explicitly turned **both** hard hide and the normal revamped battle UI OFF. Native drawing returned immediately:

- Gen I negative control: 2 visible native draw regions.
- Gen II negative control: 3 visible native draw regions.

This proves the firewall did not globally break the native fallback path; suppression is scoped to the requested presentation ownership.

## Hard-hide source invariants

All focused source assertions PASS:

- hard hide is checked before full-frame-provider defer inside `ownsNativeBattleLayer`;
- hard hide forces the replacement battle presentation even if `revampedBattleUI` is OFF;
- battle-pushed auxiliary states use the strict battle helper;
- Gen I hard-hide text/HUD lifecycle uses invisible execution rather than skipping callbacks;
- Gen II full-frame-provider `drawPanel` lifecycle uses invisible execution;
- Battle Art and Dramaless/Dramatic Shape compatibility firewalls remain present;
- FeatureParity states force their existing replacement presentation during a hard-hidden battle;
- `uiOwnership` is API v3 and publishes `hardHideNativeBattleUi(state)`.

## 2.1.38 behavior-preservation parity

Static regression comparison against the exact 2.1.38 baseline:

- mod hook registrations: **10 -> 10**
- mod event registrations: **6 -> 6**
- referenced Gen1Recomp module set: **no removals**
- user-facing option-key set: **no removals**
- pre-existing named function set: **no removals**
- manifest contract: **byte-semantically identical except version 2.1.38 -> 3.0.0**
- supported games remain `gen1` + `gen2`
- optional dependency IDs and conflict declarations unchanged

`main.lua` passes Lua syntax compilation and `manifest.json` passes JSON parsing.

## Graphical runtime boundary

The current execution environment does **not** have a runnable Gen1Recomp/LÖVE game client and Pokémon ROM mounted together, so this pass cannot honestly claim a fresh graphical ROM boot or pixel capture of 3.0.0. The test above is nevertheless an **executed full-mod runtime integration harness**, not a static-only audit: the mod entry, hooks, state wrappers, native draw lifecycles, provider contracts and repeated frame paths all execute.

The final device/game smoke test should still verify Yellow/Red/Blue and Gold with `HIDE NATIVE BATTLE UI` ON, especially while opening Party/Bag/move-learning screens during vanilla and external-renderer battles. The code-level/runtime integration gate for native-UI leakage passes before packaging.
