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

## UI-owned behavior

The mod may own layout, borders, typography, menu presentation, responsive scaling, presentation toggles, battle HUD positioning and other visual composition.

## Gen 1 / Gen 2 compatibility

Gen 1 and Gen 2 do not always share the same native renderer or menu state. Prefer generation-specific adapters around a common visual language rather than forcing one generation's state assumptions onto the other.

## Native fallbacks

When a native subsystem is tightly coupled to state and a custom renderer is not yet complete, a functional native fallback is preferred over a visually consistent but broken replacement. The Gen 2 Pokégear MAP is an intentional example in v1.4.1.

## Future refactor direction

The current stable source remains behavior-compatible with the tested 1.4.x line. Future cleanup should gradually separate battle presentation, shared drawing helpers, Gen 1 menu adapters, Gen 2 menu adapters, settings, sprite resolution and compatibility shims into smaller modules while preserving the stable public mod ID and manifest contract.
