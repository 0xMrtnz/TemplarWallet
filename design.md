# Design — Templar Wallet

The rules every screen is held to. Read this before changing a pixel. The
tokens named here live in `src/templar_wallet/lib/theme/`; the widgets that
carry them live in `lib/shared/widgets/`.

## The direction

> A photography-first interface that turns marketing into a museum gallery.
> Edge-to-edge product tiles alternate light and dark canvases, framed by
> headlines with negative letter-spacing and a single Action interactive
> color. UI chrome recedes so the product can speak — no decorative gradients,
> no shadows on chrome, only the one signature drop-shadow under product
> imagery resting on a surface. Remember that you are doing emotional design
> proved to be useful, fun and addictive to use with small dopamine rewards by
> using it. It should feel modern, slick and cool to use. It should feel yours.

## What the product is

There is no photography here, so the gallery hangs something else: **the
money**. The balance, the chart, the asset list, the amount being sent. Those
are the tiles. Everything else — headers, tabs, the carousel, section labels —
is the wall they hang on, and the wall is never the thing you look at.

Test for any new element: *does it state a fact about the user's coins, or does
it help them reach one?* If neither, it does not ship.

## The gallery

- **Ground is flat.** `AppScheme.canvas` — black on a phone, near-white in
  light mode. No page gradient inside a wallet (only the pre-wallet screens
  keep `bgGradient`).
- **Tiles lift off it.** One card tone (`AppScheme.panel`, the composited
  glass surface) and one tone above it for what sits *inside* a card
  (`AppScheme.panelInset` — icon tiles, wells). Two steps, no more. A third
  tone reads as a bug.
- **Rows, not a card each.** Repeated things (assets, activity, settings) sit
  in ONE card, separated by hairlines inset past the icon column. A stack of
  bordered cards is a stack of objects; a grouped list is one object.
- **Edges over fills.** `AppScheme.edge` hairline; radius `radiusMd` (10) for
  rows and tiles, `radiusXl` (20) for the hero.

## The one Action colour

Templar crimson `#C1121F` (`AppColors.accentDefault`, re-tinted per wallet).

- Exactly **one filled crimson control per screen** — the thing the screen
  exists for. On the Dashboard that is Send. Everything beside it is the
  neutral tile.
- Crimson also marks *state*: the centred carousel item, the selected range,
  the active nav row. Never decoration, never a background wash.
- `danger` (`#EF4444`) is a different, brighter red and is only ever used for
  loss: delete, burn, failed. Never darken it toward the accent.
- Chains own their own hues and are not the accent: Bitcoin orange, Liquid
  teal. A row about Liquid says so in teal.

## Type

- Headlines are Nunito with **negative letter-spacing** (`balanceHero`,
  `pageTitle`, `displayTitle` — the `*Of(context)` forms shrink them on a
  phone). Numbers are tabular (`AppTypography.numeric*`).
- Eyebrows are uppercase, 11 px, `letterSpacing >= 1.2`, `inkFaint`. They name
  the block below them and nothing else: `TOTAL BALANCE · TESTNET`, `ASSETS`,
  `SECURITY`.
- A figure is big and its unit is quiet: `0.01734567` at hero size, `BTC`
  beside it at caption size. The number is the product; the unit is a label.
- Never two competing headlines on one screen. The shell header names the
  page; the page does not repeat it.

## The phone's controls

Same icons, same palette as the desktop — a wallet, not two wallets. What
changes on a phone is the FEEL: fill instead of outline, bigger radii, more of
the inset grey (decided with the owner, 2026-09-06).

- **Buttons** are 54 dp tall, radius 16, and filled. Primary is the Action
  colour with white ink and the app's one shadow; secondary is `panelInset`
  with ink text and no border; tertiary is white at 4.5% — the quiet action.
  Desktop keeps its 10-radius hairline tiles.
- **Fields** are filled `panelInset`, radius 14, at least 56 dp, with no border
  at rest and a 1.5 px accent ring on focus. An uppercase 11 px label sits
  above the field rather than floating inside it. Desktop keeps its outlined
  6-radius fields.
- **Progress** is dots, not numbered circles: the Send wizard shows six dots
  and the step's name.
- **The grey does the work.** `panelInset` fills fields, glyph tiles, chips,
  segmented tracks, code boxes and stat tiles; `panel` stays the card; the nav
  bar sits one step *below* the card, because chrome recedes.

## Chrome recedes

- No shadow on chrome. The header, the carousel, tabs and rows are flat
  surfaces separated by hairlines.
- **The one signature shadow** is the crimson glow under the Send button —
  the single interactive object the whole Dashboard leads to. Nothing else in
  the app casts light.
- No decorative gradients. The only gradient in the app is the chart's area
  fill, which encodes data, and the desktop hero's specular edge, which reads
  as glass over the page gradient (and is switched off on a phone, where there
  is no gradient under it to catch).
- Icons in lists are a `panelInset` tile with a **coloured glyph**, never a
  saturated plate. Colour identifies; it does not shout.

## Emotional design

Small rewards, every one of them tied to something true:

- The chart draws itself left to right and drops a dot on "now" as it lands.
- The carousel ticks a haptic and pops the centre plate when a page changes.
- The balance flips between fiat and coin on a tap, and the chart follows it.
- Amounts echo their other unit under the field while you type, so a mistake
  is caught before Review.
- State changes are visible where the change happened: a switch flips in
  place, a copy turns into a check, a sync dot glows when it lands.

None of these animate on load past their resting state, none of them block a
tap, and all of them are skipped under `AppMotion.reduced` /
`prefers-reduced-motion`.

## Never

- A carousel or tab bar taller than a fifth of the screen.
- A control under 48 dp on touch (`AppLayout.minTouchTarget`).
- A colour defined outside `AppColors` / `AppScheme`.
- Copy that says "this computer" on a phone, or "verified" for something the
  app has not verified.
- A number the engine did not give us, presented as if it had.
