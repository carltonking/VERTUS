# AlfredMacApp (windowed companion) — monochrome WIP reference

The windowed companion app (`AlfredMac/AlfredMacApp/`) briefly carried uncommitted
changes that captured a "monochrome, no accent colors, no rounded edges" design
direction. Those changes were later discarded by a `git reset --hard` in the
workspace; this file preserves the values so the future restyle can reuse them.

## Intended palette (`Theme.swift` → `Palette.darkGray`)

- Sidebar/tab background: `RGB(10, 10, 10)`
- Main background: 4% monochrome (`Color(white: 0.04)`)
- Surface: `Color(white: 0.08)`, border `Color(white: 0.12)`
- Hairline: `Color.white.opacity(0.06)`
- Accent (neutral gray, NO blue): `Color(white: 0.3)`
  - accentDeep `white 0.2`, accentBright `white 0.5`, accentSoft `white 0.7`
- Text: primary `.white`, secondary `white 0.7`, faint `white 0.45`
- danger/success: `Color(white: 0.5)` (neutral, not tinted)
- Radii: card 0, bubble 0, composer 0 (sharp corners)
- Font size default: 12

The `Palette` struct also gained `sidebarBackground`, `backgroundView`, and
`sidebarBackgroundView` (sidebar + main surfaces were being split apart).

## Launch behavior (`AlfredMacApp.swift`)

The companion's `@NSApplicationDelegateAdaptor` gained an `AppDelegate` that, on
launch, opens `/Applications/Alfred.app` if present (the menu-bar app), so the
windowed surface could sit alongside the menu-bar backend.
