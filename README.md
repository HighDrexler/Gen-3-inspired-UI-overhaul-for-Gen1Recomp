# Gen 3 Inspired UI Overhaul — v3.0.0

A full presentation overhaul for Gen1Recomp, rebuilding the Gen I and Gen II interface around a cohesive Gen 3-inspired visual language while keeping the games' native logic, callbacks, battle rules, save data and progression authoritative.

## Install

Install the zip through the Gen1Recomp launcher, or place the `gen3_battle_ui` folder in the launcher `mods/` directory. The mod ID remains `gen3_battle_ui`, so existing settings continue to follow the same install.

Disable `colosseum_ui_overhaul` while using this mod because both mods intentionally own many of the same presentation surfaces.

## v3.0.0 release / hard native-battle-UI guarantee

Version 3.0.0 promotes the cleaned v2.1.38 codebase and makes `HIDE NATIVE BATTLE UI` a true master battle-presentation contract. While that option is ON, the mod now forces its replacement battle presentation even if the separate BATTLE UI, DIALOGUE, POKéMON MENU, BAG, LEVEL-UP, MOVE DELETER, or SERVICE/EVENT presentation toggles are individually OFF. Native gameplay state and input still run; only original battle UI pixels are prevented from reaching the frame.

The hard-hide decision also takes precedence over full-frame battle-world provider deferral. CBE, Stadium-style renderers, Battle Art, Dramaless/Dramatic Shape, vanilla battle environments, and future providers can continue to own their world/actors/camera, but none of them can cause Gen1Recomp's original HUD, command/move boxes, battle dialogue, Yes/No prompts, stat box, move-forget UI, or battle-opened Party/Bag/Summary chrome to reappear while hard hide is active. The provider-facing `uiOwnership` contract is now API v3 and exposes `hardHideNativeBattleUi(state)`.

Before packaging, the complete mod entry was executed in a Lua runtime-integration harness for both Gen I and Gen II. The harness exercised hard hide with the normal BATTLE UI and related sub-toggles deliberately OFF, with and without an active full-frame battle renderer, with Battle Art and Dramaless-style compatibility hooks present, through pushed battle TextBox/ChoiceBox/Party/Bag/MoveLearn/StatBox/MoveDeleter states, and through 750 repeated battle-draw frames per generation. A negative control then disabled hard hide and confirmed the native fallback returns normally. See `VALIDATION_3.0.0.md` for the exact scope and results.

## v2.1.38 final maintenance/performance sweep

This build performs the final conservative cleanup pass without dropping any user-facing behavior. Repeated option lookups, immutable engine-module requires, battle-provider discovery and shared layout calculations are cached at safe lifecycle boundaries; live ownership/status callbacks are still queried where compatibility depends on them. Proven dead/unreachable render code, write-only state, a no-op callback and duplicate Dramaless/Dramatic HUD wrappers were removed. Gen I and Gen II features, settings, native gameplay callbacks, sprite-provider compatibility and battle-environment compatibility remain in place.

The Gen I Item Storage fix from v2.1.37 is retained: Withdraw, Deposit and Toss are recognized from the engine's real `pc_item_*` list kinds and stay inside the custom hanging presentation.

## Major coverage

- Gen I + Gen II battle HUDs, command/move selection, battle dialogue, trainer switching, party indicators and level-up presentation
- Pokémon/Party, Summary, Move Manager, TM/HM teaching, starter selection and naming/nickname flows
- Pokédex, encounter/location data, PC/storage, item storage, Bag, PokéMart and service menus
- Save, Start, Options/UI settings, Mod Manager, Trainer Card/badges and Pokégear
- Unified overworld dialogue, location banners and wide-screen menu presentation
- User-selectable primary/secondary UI colors plus font style, size, weight, character spacing, line spacing, dialogue scale and border controls

## v2.1.36 TM/HM typography alignment

Gen II's integrated move-replacement panel now derives each move row from the active font's real measured height. The selection plate, pointer, move name, PP column and row separators stay vertically aligned across TEXT SIZE/font-profile settings, while long move names width-fit instead of using character-count truncation. Selected and unselected move names also share one fixed left edge, eliminating the horizontal jump when the cursor moves.

## v2.1 parity update

This release fills presentation gaps without replacing the established Gen 3 screens. The existing battle, Party, Summary, Bag, Pokémon PC, Pokédex, PokéMart, Save, Options, Trainer Card and Pokégear renderers are unchanged.

New presentation adapters cover Gen I item storage, starter confirmation, naming, Safari commands/status, evolution and area banners, plus Gen II clock setup, held items, mail, Mom's bank, Day Care, elevators, decorations, prizes, contests, move deletion, scripted choices, trades, Photo Studio, Unown Printer, Hall of Fame, Diploma and map/radio flows. Native state, input, callbacks, inventory, save data and progression remain authoritative. If a new adapter cannot render a runtime state safely, that individual state falls back to its native screen.

### v2.1.35 fixes

- **Gen 2 mid-battle Party/switch screens now preserve the active battle environment instead of revealing the overworld.** The Party menu becomes a transparent widescreen proxy while a live BattleState is below it: the real battle surface renders once through `BattleState:drawWidescreen()`, then the Gen 3 Party cards render on top. This keeps vanilla battle backgrounds, CBE, Stadium-style renderers, and other compatible battle-environment providers authoritative without hard-coding any one mod.
- **Removed the old CBE/full-frame `bgMode() == "world"` workaround.** In Gen1Recomp's Gen 2 compositor, `"world"` explicitly means the overworld map, not the current battle scene. During battle the Party menu now delegates the real battle's background mode, surround dim, fill behavior, and panel geometry instead. Outside battle it still uses the zero-dim world contract needed for the normal hanging Party menu.

### v2.1.34 fixes

- **Gen 2 TM/HM move replacement is now a clear, deliberate selection flow instead of a partially hidden native handoff.** The replacement panel is drawn in the same logical Party canvas as the rest of the menu, so the selected move now has a real dark focus row, orange accent rail, pointer, and readable white text. The incoming move is called out separately under `LEARNING`, the footer explicitly shows `A REPLACE / B CANCEL`, and the Party prompt changes to `Choose a move to forget.` while that picker owns the screen.
- **Fixed the truncated Gen 2 post-selection dialogue.** The compact lower strip is now used only while the actual move picker is active. Once a move is chosen, the normal full dialogue renderer takes back ownership for the complete `1, 2 and… Poof!`, forgotten-move, and learned-move pages. A stale MoveDeleter pointer is also cleared as soon as the engine pops that state so the UI cannot remain stuck in compact mode.
- **Rebuilt the Gen 2 player's Item Storage PC presentation.** Gold's `ItemPcMenu:setPhase()` was deliberately re-enabling opacity for WITHDRAW / DEPOSIT / TOSS, which caused those subflows to fall back to a full native screen even after the main PC was themed. The mod now claims the real Item PC lifecycle, keeps every phase non-opaque while the revamped Item PC toggle is enabled, and renders a hanging `ITEM STORAGE` card over the live overworld. Main actions, stored-item rows, quantities, item descriptions, move/reorder state, quantity prompts, toss confirmations, and the embedded deposit Pack now all stay inside the same Gen 3-inspired visual language while native item/storage behavior remains authoritative.

### v2.1.1 fixes

- Keeps single-line labels fitted and clipped inside their selection rows.
- Vertically centers the HP badge label and lowers battle gender glyphs slightly.
- Shows both active Pokémon's type indicators between their name/gender and level.
- Recognizes Battle Art 2.0.9's `BATTLE_ART_VOXEL_GEN2` ID and honors its INTERFACE SPRITES ownership setting.
- Uses Battle Art's exported static/animated interface-frame APIs when Battle Art owns interface sprites; MODDED/OFF correctly defer to the active external sprite provider.
- Fits menu portraits to their alpha-visible sprite bounds so custom canvases do not appear undersized or off-center.
- Makes Gen II's initial hour/minute/day setup responsive on both directional axes, with explicit confirmation selection and a readable 12-hour display.
- Renders starter confirmation once as its dedicated Gen 3 screen instead of duplicating the same ChoiceBox in the generic side-menu layer.
- Makes `HIDE NATIVE BATTLE UI` claim launcher HUD visibility, Battle Art's official presentation surfaces, and late-loading renderer guards at each battle start.

### v2.1.2 fixes

- Resolves the live `pokemon.sprite` provider before Battle Art fallbacks, so an explicitly equipped custom sprite remains authoritative in Party, PC, Summary, and Pokédex screens.
- Uses those resolved front portraits in every non-Egg Party row instead of hard-coded native menu icons.
- Invalidates decoded portrait caches when mod options change or the mod stack finishes loading.
- Suppresses the long opaque-white `Gen2MenuFade` sheet introduced by current Gen1Recomp builds whenever a replacement Gen 3 menu owns the destination, while preserving its native stack callback.

### v2.1.3 fixes

- Stops the Battle Art suppression hook from firing off the default-on `BATTLE UI` toggle. It now only fires for the explicit `HIDE NATIVE BATTLE UI` hard-suppress toggle, so Battle Art (and any compatible custom sprite provider) keeps rendering its Pokémon artwork during battle instead of being silently suppressed on every default install.
- Fixes the Bag/Pack item list's last row overlapping the description strip below it at larger `TEXT SIZE` / bold `TEXT THICKNESS` settings, by reserving clearance that grows with the user's text scale and showing fewer (still scrollable) rows instead.
- Syncs the Gen I Bag view's keyboard scrolling with the same row count used to draw it.

### v2.1.4 fixes

- Fixes the Bag/Pack selection highlight not actually containing its own row text: highlight height and row spacing now come from the label font's real measured glyph height at the current `TEXT SIZE`/`TEXT THICKNESS`, not a guessed constant sized for the default.
- Moves the battle status condition to the name row, to the right of the gender icon, instead of its own row down by the numeric HP (falls back to the old spot only when there's no gender icon or no room).
- Known gap, not yet fixed: this mod has no integration for Colosseum Battle Environments (`COLOSSEUM_BATTLE_ENVIRONMENTS`) at all, which is the most likely cause of both the missing custom battle sprites and a blank/white area covering its 3D battle scene. Needs CBE's actual render/compat hook names to fix correctly.

### v2.1.5 fixes

- Fixes a solid white box covering the battlefield whenever a full-frame 3D battle-world renderer (Colosseum Battle Environments or any other compliant renderer) is active. Root cause: this mod's own native-suppression firewall (`bottomUIVisible`/`statusHUDVisible`/`drawHUDs`/`drawTextArea`) could end up wrapped *outside* such a renderer's own native-method wrapper, short-circuiting before the renderer's ownership/compositing logic ever ran and leaving its letterboxed background unfilled.
- This is a **generic, capability-based fix, not a Colosseum Battle Environments-specific one**: at each battle boundary, the mod now scans every loaded mod's exports for either (a) the community `battleWorld`/`battleFullFrame` self-announcement contract, or (b) a `presentationOwnership(battle) -> {world=bool,...}` live-ownership query, and steps its own native suppression aside for that battle whenever either reports an active full-frame owner. No mod ID is checked anywhere in this path — any current or future 3D battle-world renderer publishing either shape is recognized the same way. This mod's own Gen 3 HUD/dialogue/command-menu chrome (drawn via the separate `render.hud` overlay pass) is unaffected and continues to draw on top.
- Because the white box was very likely also occluding the renderer's own 3D Pokémon presentation, this fix should resolve the "custom battle sprites not appearing" symptom for users of a compliant 3D battle-world renderer as well, in addition to Battle Art's suppressHook-gated sprite path fixed in v2.1.3.
- Investigated but not changed this round: Battle Art portraits still not appearing in Party/PC/Summary/Pokédex menus. The existing resolver already wires every one of those screens through the same Battle Art interface-sprite lookup used since v2.1.1 (gated on Battle Art's own INTERFACE SPRITES ownership setting), and that gating looks correct against Battle Art's documented API rather than a guess. If this is still reproducing, we need to know whether Battle Art's in-battle sprites are confirmed working now (post v2.1.3) and which specific menu(s) still show the native icon, or Battle Art's own source, to avoid guessing at its API again.

### v2.1.6 fixes

- Read Battle Art 2.0.9's actual source (`lib/AnimatedBattleArt.lua`, `lib/BattleArt.lua`, `lib/InterfaceSprites.lua`) to verify the v2.1.1-era integration against its real API instead of assumptions. Confirmed correct: species resolution, default settings (INTERFACE SPRITES defaults to BATTLE ART, BATTLE ART mode defaults to ANIMATED/GEN 5), and that the gen5 atlas data + PNG dimensions for a sampled species (Larvitar: 608x312, 16 columns x 38x52 cells x 86 frames) are internally consistent, so this is not a missing/malformed-asset problem in the build tested against.
- Given the trace shows the intended path should succeed, and every failure in the resolver chain was previously swallowed by a bare `pcall`, added throttled diagnostic logging (`mod.log`, prefixed "Gen 3 UI [Battle Art diag]") at every point this resolver can silently give up: the initial connection to Battle Art's exports (once at mod load), and the first failure per species/mode/generation thereafter, including the actual Lua error text when a Battle Art call throws instead of just returning no art. This makes zero difference to what renders; it exists so the next report of this can point at an exact cause instead of another guess.
- Always pass the engine-resolved sprite path into Battle Art's animated-atlas decoder as a fallback source, not only when it's a non-vanilla path. Battle Art's own `AnimatedBattleArt.decodeFrames` explicitly supports and safely bounds-checks an externally supplied source image for exactly the "our own bundled atlas isn't available, but another provider returned a matching one" case; the resolver wasn't taking advantage of it.
- Still open: the actual reason Battle Art interface art doesn't reach these menus for this user's install. If you can reproduce it again, check (or send) the mod log for lines starting with "Gen 3 UI [Battle Art diag]" -- that will show whether the connection to Battle Art succeeded, what its live settings read as, and the exact failure for the species involved.
- Reiterated design constraint from the user: this must stay generic to any custom sprite-providing mod, not a Battle-Art-specific integration. The generic path (the engine's own `pokemon.sprite` provider hook, resolved by `enginePortrait`/`PokemonSprites.path` and used first, ahead of any Battle-Art-specific code) is unchanged and remains the primary, mod-agnostic route; the Battle Art-specific code exists only as a fallback for the one mod that documents a bespoke non-hook API for its animated interface art.

### v2.1.7 fixes

- Colosseum Battle Environments' own COLOSSEUM MODELS setting (on by default in CBE) makes CBE's own 3D Pokemon actors authoritative and skips handing Battle Art -- or any other resolved sprite provider -- a turn at all, both in CBE's own battle compositor and in the actor-provider seam it offers UI mods for menus. That's the right behavior for CBE's sibling Colosseum Inspired UI overhaul, which is built around CBE's 3D showroom presentation, but it isn't what this mod wants: Gen 3 Inspired UI keeps Battle Art (or whichever sprite provider actually resolves) authoritative even when CBE is loaded.
- CBE doesn't expose any supported way for another mod to ask it to defer just for that mod -- no per-consumer override in any of its exports, and unlike Battle Art it doesn't expose its internals for another mod to reach into. The only lever is CBE's own persisted COLOSSEUM MODELS preference, which is a plain field in save data (the same one CBE's own BATTLE settings menu toggles). This mod now nudges that preference from CBE's default (ON) to OFF exactly once per save, the first time CBE is detected loaded alongside this mod, and never touches it again afterward. If you reopen CBE's own BATTLE menu and turn COLOSSEUM MODELS back on yourself, that stays respected -- this is a one-time default correction for this mod's use case, not an ongoing override of a setting you may want back on (e.g. if you switch to the Colosseum Inspired UI overhaul later, you'd turn it back on there yourself; this mod won't have touched it since its one-time nudge).

### v2.1.8 fixes

- Diagnosed why v2.1.6's mod-log diagnostics produced no visible output: a single shared "already logged" flag could get permanently consumed by a transient, load-order-dependent failure (Battle Art's own exports not populated yet at the instant this mod first checked) before Battle Art finished loading -- silently swallowing the real "connected" message that should have followed a moment later. Each outcome (not found / bad exports / bad module / connected) now has its own flag. Also added the one connection failure that had no log line at all in v2.1.6: `mod.find` failing to locate Battle Art by either known ID.
- Added an **on-screen** debug badge (e.g. `BA:NF`, `BA:NOFRAME`, `BA:ERR`) drawn directly on the portrait itself in Party, PC, Summary and Pokédex the moment Battle Art's interface art fails to resolve -- previous rounds only ever logged to the mod log, a file, which is a poor fit for "reproduce this in-game and tell me what happened." The badge appears only once a Battle-Art-shaped mod is actually confirmed loaded this session (never shown to a user without one), and disappears the instant resolution starts succeeding.
- Covers a case the previous diagnostics missed entirely: this resolver deliberately falls back to plain ROM/engine art when Battle Art's own attempt fails, so the portrait-drawing code always "succeeds" at drawing *something* -- it just isn't Battle Art's art. The new badge fires on that path too, since that fallback drawing the wrong sprite silently *is* the reported bug, not a non-event to skip past.
- Every failure branch in the interface-art resolver, including the raw-asset-path fallback beneath Battle Art's documented API (which had no diagnostics of its own before this), now reports the same reason to both the mod log and the on-screen badge.

### v2.1.9 fixes

- **Found the real cause of the white box on Gen II saves.** v2.1.5's fix only ever applied to Gen I's `BattleState.drawTextArea`/`drawHUDs` -- Gold's own battle presentation is drawn through a separate function, `GoldBattleState.drawPanel`, which erases the native HUD/text/menu regions with three unconditional solid-white rectangles and never checked whether a compliant 3D renderer (CBE or otherwise) already owned the battle and was compositing its own scene there. Now gated on the same `GoldCompat.ownsNativeBattleLayer()` check its neighbor `drawStatsBox` already used correctly.
- Ships with v2.1.8's Battle Art fixes included (on-screen `BA:XXXX` badge on the affected portrait, corrected diagnostic-log throttling).

### v2.1.10 fixes

- Fixes a v2.1.9 regression where the old native Gold battle UI (native HP/name boxes, native FIGHT/PACK menu) became visible again, layered underneath the styled Gen 3 HUD, whenever deferring to a 3D battle renderer (CBE). v2.1.9 gated the white-rectangle erase correctly but left the native draw call itself unconditional, so nothing suppressed it anymore. Now uses the scissor-based `runDrawInvisible` technique (already proven elsewhere in this mod) so native pixels never reach the frame at all while deferring, instead of drawing them and then trying to hide them. The non-3D-renderer case is unchanged.
- Applied the same fix preemptively to Gold's native stat/level card (`drawStatsBox`), which had the identical latent issue.

### v2.1.11 fixes

- Battle Art is now asked for its art FIRST in Party/PC/Summary/Pokédex, rather than only as a fallback behind the generic engine sprite provider. Battle Art's own generic hook always defers under its own default settings anyway, so this can't steal art from a different provider -- but the old order meant Battle Art's bespoke API (and every diagnostic around it) could be skipped entirely if the engine's own resolved path ever differed from the vanilla reference string for a menu screen, for reasons unrelated to any real custom provider. This is the most likely reason nothing ever showed and nothing ever logged.
- Fixed the on-screen debug badge itself: it was rendering as a plain red bar with no legible text because its font size was tied to the height of the thin strip it drew in. Now uses a fixed legible size and sizes the background to the text instead.

### v2.1.12 fixes

- Fixed the debug badge still being unreadable after v2.1.11's sizing fix: a shader used elsewhere in this mod to strip white mattes off Battle Art images (`GoldCompat.menuPortraitShader`) was still bound when the badge drew, and since it makes near-white pixels fully transparent, it was silently erasing the badge's own white text. (`love.graphics.push("all")` only saves shader state to restore later -- it does not clear an active shader for draws made before the matching `pop`.) The badge now explicitly clears any bound shader before drawing itself, and uses black text on a yellow background instead of white on red as extra protection against this exact failure mode. The badge should now be legible; if Battle Art's art still doesn't appear, it will show a specific `BA:XXXX` code identifying why.

### v2.1.13 fixes

- Fixed "PLEASE WAIT" showing a solid box instead of "..." on the Elevator and other transitional service screens -- the pixel font has no glyph for the real ellipsis character that was being used, so replaced it with three periods.
- TM/HM rows in Gen 2's Bag (TM/HM tab) now show the move a TM teaches, matching how HMs already displayed there and how Gen 1's Bag already worked -- previously TMs only showed a "x1" count. The Poké Mart's BUY list also now shows a TM/HM's move name when one is in stock.
- Hardened Options, Mods Manager, Trainer Card and Save Menu (Gen 1 and Gen 2) against a class of bug already found and fixed once this session for the battle HUD: this mod was skipping their native `draw()` entirely instead of just hiding it, which risks starving any per-frame bookkeeping that draw call happens to also perform. All four now run their native draw invisibly (zero-size scissor) instead of skipping it outright. This does not touch input/navigation handling, which this mod was already confirmed not to alter for any of these screens in either generation.

### v2.1.14 fixes

- The Elevator's real complaint -- it never shows floors as a selectable option, not just a font glitch -- turned out to be a separate bug from v2.1.13's ellipsis fix. This mod's generic restyled-menu row lookup only recognized a fixed set of native field names, and whatever field Gen1Recomp's ElevatorMenu keeps its floor list under wasn't among them, so it always read as zero rows and stayed on "please wait" forever. Widened the lookup (also tries floors/destinations/stations/options/choices/picks, and a few more nested containers) and widened the selection-index lookup the same way. This also affects every other screen sharing this same generic renderer (Decoration, Prize Exchange, Contest, Move Deleter, Script Choice, Trade, Photo Studio, Unown Printer, Hall of Fame, Diploma, Map/Radio, Mail, Bank, Day Care), so any of those with the same symptom should improve too.
- Also hardened that same group of screens against native draw being skipped entirely instead of run invisibly, matching the same fix already applied to Options/Mods/Trainer Card/Save Menu -- in case a native flow only builds its own list inside its own draw call.
- Neither fix could be verified against Gen1Recomp's own source. If the Elevator still doesn't show floors after this build, the real field name wasn't among the ones tried and needs a fresh report.

### v2.1.15 fixes

- TM/HM move names in Gen 2's Bag TM/HM tab were still not showing for TMs after v2.1.13's fix -- the lookup relied on a `pack.game`/`mart.game` field that the native Pack Menu/Mart Menu doesn't actually have, so it silently did nothing for every row. Now falls back to this mod's own live game-data handle, and tries every plausible field on the row for the item id instead of a fixed guessed list. Applied to both the Bag and the Poké Mart BUY listing.
- Fixed a real bug behind the reported "glass/fisheye" warping on the battle background behind the Bag (and Mart/PC) menu, especially with Colosseum Battle Environments' 3D battle scenes: this mod's Pack/Mart/Center PC screens were skipping their native draw call entirely instead of just hiding it, the same anti-pattern already found and fixed on every other screen. If a 3D battle renderer's own per-frame update piggybacks on that native draw call, skipping it would leave it working from stale state the whole time the Bag was open. Fixed by running it invisibly instead, and made the invisible-draw technique itself safer (a genuine off-canvas box instead of a literal zero-size clip region, which is an edge case some renderers handle unpredictably). Also closed two related gaps in the Pokégear/Pokédex screen-capture code that could leave the screen's canvas in a bad state if a native draw call inside them ever failed.
- The native location banner still appearing alongside this mod's own custom one couldn't be fixed blind -- this mod's banner has always been purely additive, and there's no visibility into what native class draws the other one. Added a one-time diagnostic log instead that reports the real native field names next time, rather than another guess.

### v2.1.16 fixes

- Made an actual attempt at suppressing the duplicate native location banner (v2.1.15 only added diagnostic logging) by trying a range of plausible native module paths, the same way every other native screen in this mod was originally found, and suppressing whichever one(s) resolve. Best-effort guess, logged either way.
- Fixed Bag scrolling breaking past roughly the 4th item (selection highlight disappearing entirely): the visible row window was tracking the native scroll field directly instead of clamping around the selected item like every other restyled list in this mod already does.
- Fixed Item PC storage still being fully vanilla on Gen 2: its toggle was Gen-1-only by mistake, its dedicated renderer had no fallback or logging if its one guessed native class name was wrong, and it's now also covered by the same generic restyled-screen safety net Gen 2's other service menus (Elevator, Mail, Bank, etc.) already use.
- Fixed dialogue text displaying left-heavy with a lot of unused space: it was using the native engine's line breaks verbatim, which are wrapped for native's own narrower box, not this mod's wider one. Finished lines of dialogue now reflow to use the full width of the box, at any font/text size setting, using the same technique already proven for battle dialogue.

### v2.1.17 fixes

First pass of a Gen 1 parity sweep (Gen 1 had never actually been tested this project -- all prior rounds were verified on Gen 2 only):

- Reverted a speculative scissor-rect change from two builds ago that's the most likely actual cause of Gen 1 breaking -- it affected the single highest-traffic suppression path in the whole mod, used on every Gen 1 battle frame.
- Fixed Gen 1's Options/Trainer Card screens never actually finishing their opacity/ownership setup until their first draw (a dead `.update()` patch, silently never wired up).
- Fixed Gen 1's Bag ignoring its own text-size-aware row count and using a hardcoded 6 rows instead, which could disagree with its scroll position at non-default TEXT SIZE.
- Fixed the enemy trainer intro indicator always showing 6 balls regardless of actual party size on Gen 1.
- Removed a Gen 1 toggle for a Gen-2-only feature (held items don't exist in Gen 1).

This is a strong first pass from code audit, not a guarantee -- please retest Gen 1 broadly.

### v2.1.18 fixes

First build verified against the real Gen1Recomp engine source (previous builds guessed native class/field names from behavior alone):

- **Likely headline fix:** every one of this mod's ~35 error/info log calls used the wrong calling convention for the real engine's mod API (`mod.log:info(...)` is required; `mod.log("info",...)` throws). Because these calls sit in the fallback path that's only reached when a screen's own draw call fails, this turned every ordinary, anticipated single-screen failure into a silent, uncaught crash of the mod's *entire* per-frame overlay render hook -- which the engine then quietly falls back to native rendering for, forever, for the rest of the session, with nothing visible to the player. This is the single most likely explanation for "the mod does literally nothing." All call sites fixed.
- Fixed Gen 1's Options menu drawing the wrong list against the wrong index (native keeps two separate row lists; this mod was mixing one's rows with the other's cursor position).
- Fixed Gen 2's Item Storage PC screen for real: the class was already correct, but the patch was attached to a method the engine never actually calls for that class.
- Fixed the native Crystal location banner duplication with the real class and function now identified (Gold/Silver never show this banner at all, so nothing changes there).
- Minor: corrected the dialogue box's next-page arrow blink rate, and added a couple of missing native option fields to Gen 1's TM/HM teach flow.
- Known remaining gap: the optional WIDE battle layout setting (off by default) bypasses this mod's battle UI suppression entirely; tracked for a follow-up rather than rushed into this build.

### v2.1.19 fixes

- Fixed a literal `{PROMPT}` tag appearing at the end of Gen 1 battle messages ("Wild PIDGEY appeared!{PROMPT}"). The engine's own message text keeps this trailing marker un-stripped on the object this mod reads from; now stripped the same way the engine's own renderer does before typing a line. Battle-only (Gen 1) -- overworld dialogue and Gen 2 battle text were never affected.

### v2.1.20 fixes

**Built the Gen 1 Pokédex** -- confirmed via screenshots to be completely vanilla; a missing feature, not a bug, and the largest addition to this mod in some time:

- The CONTENTS list is now fully restyled, reusing this mod's existing Gold/Crystal Pokédex renderer directly -- Gen 1's real list class turned out to already match its expected shape field-for-field once read.
- The DATA entry page needed no new code: this mod already had a complete, correct renderer for it that had simply never been reachable without a working CONTENTS screen in front of it.
- Fixed a real double-draw bug in the DATA/CRY/AREA/PRNT/QUIT side menu, caused by native code overwriting its own menu instance's draw method after this mod had already claimed it.
- CRY and QUIT needed no visual changes. AREA (Town Map) and Yellow's PRNT (GB Printer) are left native for this build as a deliberate scope decision -- Town Map is a large, separate, multi-purpose screen.

### v2.1.21 fixes

- **Fixed native battle UI (command box, enemy/player name+HP corner boxes) leaking through during a 3D battle** (e.g. with Colosseum Battle Environments active), confirmed by screenshot. This mod used to trust a detected full-frame 3D renderer to suppress the classic 2D chrome itself and step fully aside -- that trust was misplaced. Suppression is now unconditional, using the same zero-area-scissor technique already proven safe regardless of a 3D renderer elsewhere in this mod. HIDE NATIVE BATTLE UI is an absolute rule now, with no exceptions for a third-party battle renderer being active.
- **Fixed Gen 1's Pokémon PC (Bill's PC WITHDRAW/DEPOSIT/RELEASE POKéMON) showing a fully vanilla Pokémon list**, confirmed by screenshot -- Gen 2's PC was unaffected. Gen 1's real PC list screens identify themselves differently than Gen 2's do, and this mod's detection only recognized Gen 2's way of doing it. Bill's PC main menu and the per-Pokémon action card were already working; only the list itself was affected.
  - Known related gap, not confirmed broken and not fixed this round: the CHANGE BOX picker screen, and Gen 1's separate Item PC (WITHDRAW/DEPOSIT/TOSS ITEM). Flagging both as likely needing the same fix in a follow-up.

### v2.1.22 fixes

- **Fixed the move-select panel covering the player's HP plate**, confirmed by screenshot. The plate has always positioned itself relative to the FIGHT/POKéMON/BAG/RUN command panel's height, but the 4-move list panel that replaces it once you press FIGHT is taller -- so its top edge climbed up over the bottom of the plate. It now anchors to whichever panel is actually showing. Applies to both Gen 1 and Gen 2 battles.
- **Added a MOVE MENU LAYOUT setting** with two options: **4X1 LIST** (the existing vertical layout, default) and **2X2 GRID** (a shorter, four-cell grid sized to match the command panel exactly, so the HP plate never has to move for it). Selecting GRID also switches move-cursor navigation to all four directions, using the same grid-navigation hook point the engine's own WIDE battle layout already uses -- so pressing left/right/up/down lands on the visually adjacent move, not just the next one in list order.

### v2.1.23 fixes

Four Gen 1 items reported together with screenshots; three fixed, one (FLY) needs a clarifying detail before it can be safely built and is untouched this build.

- **Fixed the Gen 1 Poké Mart still showing vanilla chrome**, confirmed by screenshots of both the BUY/SELL/EXIT counter and the SELL item list. The counter's MONEY box and clerk greeting text are drawn straight onto the canvas by native code, bypassing this mod's theming entirely, and an instance-level override on the counter menu was shadowing the class-level patch that would have restyled the panel around them -- the same class of bug already fixed twice before for other screens. The BUY/SELL item lists never matched this mod's existing (but wrongly-targeted) shop-list detection at all, so they fell through to fully native; detection is now based on the item shape itself rather than a title string neither list actually sets. Also removed a dead, order-of-declaration-broken renderer that silently failed every time it was called.
- **Fixed the Gen 1 SAVE screen's PLAYER/BADGES/POKéDEX/TIME info panel showing fully vanilla**, confirmed by screenshot. This panel is a one-off table pushed directly onto the stack by native code, not an instance of any class this mod could patch the usual way, and an existing themed renderer for it had been sitting completely dead since it was written due to a wrong assumption about how the native text is composed. Now hooked at the stack-push level and rendered with a new, verified-correct renderer; the separate "Would you like to SAVE the game?" Yes/No confirmation already gets this mod's normal dialogue theming, so the two now render consistently side by side.
- **Fixed the Gen 1 party screen's MOVES card not adapting to TEXT SIZE / TEXT THICKNESS settings**, reported with a screenshot. Move-row height and name truncation were both sized for the smallest text settings; at larger sizes the 4th move row could spill into the ATK/DEF/SPD/SPC footer below it, and names were cut at a fixed character count regardless of actual rendered width. Both now measure the real font metrics at the user's current settings and fit themselves to the available space -- all 4 moves always stay visible, sized to whatever actually fits.
- **Not fixed: the FLY menu.** The reported "FLY / CANCEL" 2-item box over the overworld doesn't match any code path found after a thorough source read (the party screen's own FLY entry always appears alongside MOVES/STATS/SWITCH/CANCEL, and choosing it opens the graphical Town Map, not a text list). Needs a clarifying detail from the user before a fix is attempted, rather than guessing at the wrong screen.

### v2.1.24 fixes

- **Fixed a regression from v2.1.23's MOVES-card font-fit change**, confirmed by screenshot showing it clipping worse than before. The new height estimate used to size move rows was extrapolated from a single reference measurement and came out lower than the real rendered glyph height, so rows packed tighter than the old fixed spacing did. Now asks the actual font for its real height at the exact size it renders with, the same way move-name width was already measured, and widened row padding to match the margin already used elsewhere for this kind of fit.
- **Built the Gen 1 elevator floor picker** (Celadon Mart, Silph Co, Rocket Hideout), confirmed vanilla by screenshot. This was a screen this mod's menu detection simply didn't cover yet, not a sign of deeper Gen 1 breakage -- a previous elevator fix in this project's history checked field names against Gen 2's own separate elevator class, which Gen 1 never uses. Added a real floating floor-list card matching how native shows it directly over the map, with scroll indicators for longer lists like Silph Co's.
- **Scoped for next round: Poké Mart SELL cycling Bag categories like Gen 2's does.** Gen 2 gets this for free because its native Mart hands over a live Bag reference during SELL; Gen 1's real sell flow has no equivalent and needs its own category-sorting and tab UI built, which is real feature work rather than a quick fix.

### v2.1.25 fixes

- **Built Poké Mart SELL category cycling, correcting how v2.1.24 scoped it.** That entry assumed Gen 1's item-to-pocket mapping needed new work; the user corrected this directly -- the Bag's own ITEMS/BALLS/KEY/TM-HM categorization already exists and works, and the Mart's item menu was the only one missing it. Reused that existing categorization outright and built only the piece that was actually missing: an adapter for the Mart's SELL list (which, unlike the Bag, is a flat one-shot list with no live inventory reference of its own, and whose choose/reorder/consume actions are real game logic operating on that list's native index) so it can drive the same category tabs and Left/Right cycling the Bag already has. CANCEL stays selectable as its own row while browsing any pocket, and the existing SELECT-to-reorder feature still works from inside the categorized view. BUY is unchanged -- only SELL was requested.

### v2.1.26 fixes

Three fixes from one round of reports: the MOVES card overlap "kept getting worse" across two prior attempts, the same card also affects the PC menu, Gen 2's TM/HM flow doesn't share Gen 1's Pokémon-menu integration, and the Pokémon/Party menu should hang transparently over the overworld on both games instead of painting a solid background.

- **Root-caused the MOVES card overlap for real this time, fixing it in both Party and PC.** The "NONES"-looking text and the overlap into the ATK/DEF/SPD/SPC footer are one bug, not two -- rendering the real pixel font at the tiny sizes the old shrink-loop bottomed out at makes "MOVES" and "NONES" nearly indistinguishable. The actual defect neither v2.1.23 nor v2.1.24 caught: the real glyph height at these sizes runs ~1.9-2.0x nominal, not the ~1.2x the budget math assumed, so the shrink loop always hit its floor while still overflowing. Fixed by removing the redundant "MOVES" header and tightening row spacing, validated against the real measured ratio across every realistic TEXT SIZE/screen-scale combination. `drawPartyDetails` is shared by both the Party and PC menu cards, so this fixes both surfaces with one change.
- **Built Gen 2's TM/HM teach flow into the reskinned Pokémon menu, matching Gen 1's flow exactly.** Gen 2's real TM/HM picker pushes an entirely separate native class from Gen 1's, and this mod's TM/HM integration (the ABLE/NOT ABLE badge, the move-replace panel) had only ever been wired onto Gen 1's. Wired the same mechanism onto Gen 2's class -- reusing Gen 2's own native `tmhmAble` method for the badge and Gen 1's existing move-replace panel outright for the replace step, rather than building a separate Gen 2-specific version of either.
- **Made the Pokémon/Party menu hang cleanly over the overworld on both Gen 1 and Gen 2, instead of a solid background.** Both games' native party menu classes hardcode themselves as opaque to the engine's state stack, which was telling the engine never to render the overworld underneath at all -- independent of this mod's own drawing, which was never painting a solid backplate of its own. Fixed by marking both classes non-opaque at patch time, the same fix already proven safe elsewhere in this mod (Trainer Card, Mod Manager).

### v2.1.27 fixes

Follow-up after v2.1.26 testing: Gen 2's party menu still had a solid background, Gen 2's Bag didn't show TM move names, and a report about the enemy trainer's sprite reappearing mid-battle turned out to most likely be correct vanilla behavior.

- **Fixed Gen 2's Pokémon menu still painting a solid background.** v2.1.26's `isOpaque=false` fix was necessary but not enough -- it only tells the engine the overworld underneath is safe to skip rendering, not what this mod's own draw call paints on top of it. Gen 2's renderer had a leftover full-canvas opaque fill (a literal port of Gen 1's old, pre-hanging-panel layout) that immediately covered the overworld back up. Removed it, matching how Gen 1's own renderer already avoids this.
- **Fixed TM/HM items in Gen 2's Bag not showing which move they teach.** Two stacked bugs: the move-name lookup only checked Gen 1's item-data shape, never Gen 2's real one (confirmed by reading the actual extractor and Mart source); and even once that's fixed, the row-drawing code's `if/elseif` let the TM's quantity count always win over showing the move name, since native legitimately sets both at once for a TM row. Now shows the move name for every TM/HM row on both games, matching the existing Gen 1 behavior.
- **Investigated, not changed: the enemy trainer's sprite reappearing when they switch Pokémon.** Reading the real Gen 2 battle source confirms this is intentional -- the games really do show the trainer's own sprite during the "TRAINER is about to use MON. Will you change POKéMON?" prompt, and this mod's overlay was built specifically to replicate that. Nothing in source points to a bug here; flagging for a follow-up report with more detail in case something else is actually wrong.

### v2.1.28 fixes

- **Fixed Gen 2's Pokémon menu showing solid black instead of the live overworld behind the transparent card.** Gen 2's real render pipeline has no Gen 1 equivalent for drawing the map behind a full-screen menu outside of battle -- it only ever does so when something in the state stack offers a `bgMode` of "world", a contract only the battle screen provided before. The party menu now provides that too when opened normally, while still deferring to the real battle's own background setting when opened mid-battle.
- **General sweep: every restyled menu's selection highlight and row spacing now scales with TEXT SIZE/TEXT THICKNESS.** Previously only the Bag/Pack/PC list measured the real font height to size its rows; about a dozen other menus (the elevator floor picker, START menu and its UI Options submenu, the Bag action submenu, the battle move-replace panel, Bill's PC action list, the Pokédex list and its action flyout, the Gen 2 UI settings panel, the Gen 1 Options menu, and the Mod Manager) used a fixed pixel row height that never changed with the user's settings. All now measure their own real label size the same way, so the whole mod now scales consistently.

### v2.1.29 fixes

- **Fixed the distracting black borders around every party card/row left over from v2.1.28's transparency fix.** The shared card/row frame used a flat, unshadowed near-black fill that blended into this screen's old opaque black backdrop but now stands out starkly against the live overworld behind it. Given the same soft-shadow, lighter-edge floating-panel treatment already used elsewhere in the mod. Cosmetic only -- no layout or input changed, and Gen 1's party screen (which shares the same code) improves too.
- **Fixed Gen 2's TM/HM teach flow dropping to a plain, unstyled "MOVE DELETER" screen whenever the target Pokémon's moveset was already full.** That screen is also the real standalone Move Deleter NPC and the Ether/Elixir PP-restore picker, so it couldn't simply be retargeted -- and Gen 2 additionally pops its own party screen before this step runs, unlike Gen 1, which keeps it open throughout. The party card is now kept alive and redrawn as a background for the whole announce-and-forget dialogue chain, and the forget-list step itself now flips the party card's move strip into the same REPLACE MOVE panel Gen 1's TM/HM flow already uses, instead of showing the generic screen. A mid-battle level-up forget-prompt or a Move Tutor NPC that doesn't open the party card first still shows the generic screen for now.
- **Not yet built: the requested Move Manager delete/restore feature for both generations' party moves view.** Neither game's engine keeps a record of previously-known moves, so a "restore" can only ever cover moves forgotten through this new manager itself going forward. Proposed shape (SELECT on a calmly-browsed party card, delete down to a minimum of 1 move including HMs, restore only what was deleted this session) is written up for confirmation before the input-handling is built.

### v2.1.30 fixes

- **Fixed the Gen 1 field-move submenu's (SURF/STATS/MOVES/SWITCH/CANCEL) selection cursor sitting off-center against its own label.** Row pitch and highlight height were fixed constants that no longer matched the label's real glyph height at anything but the default TEXT SIZE. Now derives both from the label's actual measured font size, the same fix already applied to the Bag/Pack list and about a dozen other menus in v2.1.28 -- this submenu was simply missed by that sweep.
- **Fixed the TM/HM integrated dialogue box burying the party card's move-replace list underneath it.** The "which move should be forgotten?" message stays on screen for the whole pick, at a height that overlapped the card's own move rows in the same bottom slice of the screen. Now shrinks to a compact height specifically during this flow (both generations) so it sits below the card instead of over it, with no loss of message content.
- **Redesigned the party card/row frame to be genuinely transparent, per direct correction of v2.1.29's border fix.** That build only lightened the opaque edge fill from near-black to charcoal -- still a solid box. Dropped the opaque fill entirely in favor of a soft shadow and a thin outline only, so the overworld now actually shows through.
- **Rebuilt the "MOVE MANAGER" (Gen 2) to replace moves from the Pokémon's current-level learnset, not just reorder the existing four.** Corrects the wrong scope proposed in v2.1.29. Highlight a move row and press START to open a list of every move the Pokémon can learn at or below its current level that it doesn't already know, and confirm to swap it into that slot -- using the same move-entry shape and `pokemon.move_learned` event the game's own move-learning code uses, so other mods see it as a real learn. Gen 1 has no equivalent Move Manager entry point yet in the base engine and needs a separate screen built for it; not yet done.

### v2.1.31 fixes

- **Rebuilt the Move Manager from scratch on both generations, replacing v2.1.30's non-functional Gen 2-only design.** Built from reading a working reference implementation the user supplied (their own sibling mod, sharing this mod's architecture), then reskinned into this mod's own cream-panel visual style rather than the reference's own look. Highlight one of a Pokémon's 4 current moves, press A to manage it, then choose DELETE MOVE or any move it can currently relearn (its level-up learnset, walked back through pre-evolutions, plus every move this manager has ever seen on it) and press A again to apply. Gen 2 keeps the same SELECT entry point as before; Gen 1 gets the same manager for the first time, using SELECT on its moves page, confirmed free in the real engine.
- **Fixed Gen 2's TM/HM party picker marking every Pokémon as ABLE regardless of whether it could actually learn the move.** The native `tmhmAble` method returns a string, not a boolean, and both possible strings are truthy -- so the badge always showed ABLE. Now derives the boolean directly from the species' own TM/HM list, matching Gen 1's existing correct logic.
- **Suppressed the enemy trainer's switch-in sprite overlay when a full-frame 3D battle renderer (such as CBE) owns the battle.** Still genuine, correct vanilla presentation for this mod's own default battle view -- just skipped specifically when a compliant full-frame renderer has taken over the scene, matching how this mod already defers to one everywhere else.
- **Attempted fix, unverified: the party menu showing solid black instead of hanging over the battle during a mid-battle forced switch.** Now forces the overworld-style background path when a full-frame 3D renderer is confirmed active, on the reasoning that its own scene should show through instead. Flagged honestly as a best guess with no access to that renderer's own source to confirm it -- report back if the screen is still black.
- **Border report re-checked, no further action.** The accompanying screenshot appears to be the same evidence shown before v2.1.30 shipped; a later screenshot from the same batch already shows v2.1.30's fix working correctly.

### v2.1.32 fixes

- **Fixed the Gen 1 Move Manager never appearing at all.** It only opened when SELECT was pressed on the MOVES page specifically, but a Summary always opens on the STATS page first -- so the natural first attempt (SELECT right after opening a Pokémon) looked like the feature didn't exist. Now opens from either page, matching Gen 2, with a footer hint added to the STATS page too.
- **Fixed the Move Manager being impossible to exit once opened (Gen 2).** Closing it left a native field set that made both the input handler and the renderer think the manager should reopen on the very next frame -- so B appeared to do nothing. Now clears that field on close, so backing out actually works.
- **Fixed the Move Manager's own panel frames showing the same thick black border already fixed for the party list.** Its card chrome was carried over unchanged from the old reorder-only screen and never got the same soft-shadow-plus-thin-outline treatment. Now matches the party cards' style on both generations.

## Compatibility priorities

The mod is presentation-only. Pokémon artwork is resolved through the active Gen1Recomp/mod sprite pipeline rather than replaced by a private sprite source, so Battle Arts, ROM sprites and compatible custom sprite packs can remain authoritative. The same resolved sprite source is reused across battle, Party, Summary, PC and Pokédex where possible.

When **Battle UI** is enabled, the mod owns battle interface presentation completely: native command/status HUD chrome is suppressed while the battlefield and externally supplied Pokémon artwork remain available to compatible renderer/sprite mods.

## Notes

- Supports Gen I and Gen II.
- Launcher API: 2.
- Conflicts with `colosseum_ui_overhaul`.
- Gameplay mechanics are not intentionally changed by this mod.
