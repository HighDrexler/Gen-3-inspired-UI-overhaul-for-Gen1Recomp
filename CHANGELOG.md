# Changelog

## Unreleased

- Party, PC, Summary, and Pokédex portraits now use Battle Art's DV-confirmed
  shiny front collection when `DUPLICATE FIX` is `BATTLE ART`. Animated sets
  intentionally display their first frame in menus, with separate normal and
  shiny atlas caches and the canonical `genN/shiny` asset layout.
- Battle Art `MODDED` ownership now bypasses Battle Art portraits for ordinary
  and shiny Pokémon alike, allowing the live sprite-provider chain to choose
  the correct Party, Summary, PC, and Pokédex image.
- Battle Party selection now masks underlying shiny-reveal sparkles only across
  its middle content band, preserving the top title/DV overlay and bottom
  switch prompt. All Pokémon cards use borderless cream faces with the brown
  rounded outline as the sole selection marker.

## v1.4.1

Stable maintenance and cleanup release based on the final v1.4.13 test feature set.

- Promoted the current tested Gen 1 + Gen 2 feature set to a stable baseline.
- Preserved all current battle, Party, PC, Pokédex, Bag, Summary, Move Manager, menu and compatibility behavior.
- Preserved adaptive text/UI scaling and mobile battle HUD options.
- Preserved Gen 2 Pokédex catch-location workflow and vanilla-functional Pokégear MAP fallback.
- Performed behavior-preserving source cleanup for easier future development.
- Established this repository as the canonical project/update location.
- Kept the stable mod ID `gen3_battle_ui` for continuous launcher/update discovery.

### Maintenance contract

The UI mod owns presentation. Engine/native systems continue to own battle state, Pokémon data, storage semantics, evolution, move learning, Move Manager behavior and other gameplay-sensitive state wherever possible.

## Development history

The 1.4.1 stable baseline incorporates the fixes validated through the v1.4.13-test development line. Detailed historical test notes remain in the packaged source changelog.
