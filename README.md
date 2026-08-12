# Gen 3 Inspired UI Overhaul for Gen1Recomp

A presentation-focused UI overhaul for Pokémon Red/Blue/Yellow and Pokémon Gold/Silver/Crystal in Gen1Recomp, inspired by Generation III while preserving native gameplay logic.

## Current stable release

**v1.4.1** is the stable maintenance baseline. It promotes the complete tested v1.4.13 development feature set and performs a behavior-preserving cleanup for future development.

## Highlights

- Gen 3-inspired battle HUD, command menu, move selection and dialogue
- Redesigned Party, PC, Pokédex, Bag, Start, Options, Mods and Trainer screens
- Gen 1 and Gen 2 UI support
- Native-backed Move Manager integration
- Gen 2 Pokédex catch-location screen
- Mobile/iOS battle HUD option
- Text size, text weight and UI box scaling controls
- Battle Arts resolved-sprite compatibility
- Presentation-only design: battle state and gameplay logic remain engine-owned

## Repository direction

Beginning with v1.4.1, this repository is the canonical home of the mod. Source, documentation and future release history belong here rather than in version-specific updater repositories.

The project deliberately keeps gameplay-sensitive systems native wherever possible. See `ARCHITECTURE.md` in the v1.4.1 source package for the maintenance and compatibility boundaries used during development.

## Installation

Install through the Gen1Recomp launcher/mod workflow when available, or install the packaged release according to Gen1Recomp's normal mod installation process.

## Updating

Future stable versions will keep the same mod ID (`gen3_battle_ui`) and canonical GitHub repository so launcher update discovery can follow one continuous project instead of jumping between version-specific repositories.

## Compatibility philosophy

This mod owns presentation, not Pokémon/gameplay state. Battle Arts and other sprite providers remain responsible for resolved Pokémon artwork; the UI consumes the active resolved sprite source rather than replacing it.

## Development

Current stable baseline: **1.4.1**

Canonical repository: `HighDrexler/Gen-3-inspired-UI-overhaul-for-Gen1Recomp`
