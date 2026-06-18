# Riso UI Consistency Checklist

Run through this when building or reviewing any iOS "Riso" surface. It exists
because the most common drift is **hand-rolling a control instead of using the
kit** — which silently diverges in font, padding, color, and wrapping. The
canonical components live in `apps/ios/OYBC/Views/Riso/RisoControls.swift`;
tokens in `RisoTheme.swift`; the visual gallery (snapshot-baselined in light +
dark) is `RisoKitGallery` / `RisoKitSnapshotTests`.

## Use the kit — don't hand-roll

- [ ] **Buttons** → `RisoButton` (sizes: default / `large` for hero CTAs /
      `small` for inline rows). Not a raw `Button` with manual
      `.background(RoundedRectangle).overlay(strokeBorder)`.
- [ ] **Toolbar Done / Save / Delete** → `RisoToolbarPill` (gold default;
      `fill: .risoRed, foreground: .risoPaper` for destructive). Not a
      hand-rolled `Capsule().fill(...)` pill.
- [ ] **Segmented controls** → `RisoSegmented` (`equalWidth: false` when labels
      differ in length; `selectedFill:` for per-value color coding). Not a
      `ForEach` + `Button` + `RoundedRectangle` reimplementation — and never
      `Picker(.segmented)` (UISegmentedControl ignores per-`Text` fonts and
      clips long labels; see the picker-segmented-font pitfall).
- [ ] **Filter / toggle chips** → `RisoChip` (use `systemImage:` for an icon
      chip like "Filters").
- [ ] **Text inputs** → `RisoTextField` / `RisoNumberField`. No private
      `risoTextInput` / `risoNumberInput` copies (Extract-at-three).
- [ ] **Type indicators** → `RisoTypeBadge`.

## Tokens — not magic numbers

- [ ] **Colors** are `Color.riso*`. Never `Color.blue/.orange/.indigo`,
      `.systemGray*`, `.white/.black`, `.primary/.secondary`, or raw
      `Color(red:green:blue:)`.
- [ ] **Fonts** are `.risoHead(...)` / `.risoBody(...)`. Never
      `.system(size:)`, `.font(.headline)`, or bare `.fontWeight(...)`.
- [ ] **Radius** = `Riso.cardRadius` (cards/controls) or `Riso.cellRadius`
      (board cells). **Keyline** = `Riso.Keyline.container` (2pt) or `.dense`.
      **Spacing/padding** from `Riso.gutter` / `Riso.cardPadding`.

## Layout & sizing

- [ ] Full-screen backgrounds (`RisoPaperBackground`) sit in a **bounded**
      container (the `NavigationStack` / ZStack root) — NEVER inside a
      `ScrollView`. Inside a scroll view a full-bleed `Color` gets unbounded
      height, collapses to content height, and the system white shows through.
- [ ] Do **not** apply `.fixedSize()` to a `RisoSegmented` — it defeats
      equal-width and clips the longest label. Use `equalWidth: false` or
      constrain the container width instead.
- [ ] Tap targets are ≥ 44pt (icon buttons, ± steppers, pager chevrons).
- [ ] Control labels can't wrap/clip — rely on `RisoSegmented`'s built-in
      `lineLimit(1)` + `minimumScaleFactor(0.8)`, or shorten the labels.

## Verify before committing

- [ ] Run `RisoKitSnapshotTests` (light + dark) — the canonical component
      gallery. Re-record + view the baselines if you changed the kit.
- [ ] Add a snapshot test for any new surface (see CLAUDE.md §iOS snapshot tests).
- [ ] Grep sweep for drift:
      `Color\.(blue|orange|indigo|systemGray|white|primary|secondary)`,
      `\.system\(size:`, `Picker.*segmented`, and `\.fixedSize\(\)` near a
      segmented control.
