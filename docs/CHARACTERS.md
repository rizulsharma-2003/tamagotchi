# Characters

Both characters are drawn procedurally in code (`Sources/App/Rendering`), so they scale crisply from
the menu bar to the app icon and need no external assets. Mochi is an original character; the
companion is drawn after the Claude Code pixel mascot, at the user's request (see the note at the end).

## Mochi — your pet

- **Silhouette**: a soft, round, bean-shaped body (60 × 54 units) with two short rounded ears, tucked
  nub arms, little feet and a short tail with a fluffy curl. Reads as a cat-like blob at 18 pt.
- **Personality**: curious, affectionate, mischievous; enjoys attention but never demands it.
- **Animation language**: squash and stretch, bouncy springs, organic sway; breathing and natural
  blinking continue under every animation.
- **Face**: big glossy eyes (open, wide, happy ^^, closed, sleepy, worried, dizzy, heart, wink), brows
  (worried, raised, confused), mouths (cat ω, smile, open, o, flat, wavy, blep, nom, yawn), blush.
- **Coats**: cream, peach, mint, sky, lavender, cocoa, midnight (light eyes).
- **States**: idle, sleep (Z's), watch, gentle wave · look around, happy bounce, excited jump, roll,
  dance, confused tilt, concerned (sweat drop), victory (confetti), greet, petted (hearts), play (ball),
  lean forward, nod, blep, yawn, treat (cookie), wake up, wave · building blocks for interactions: walk,
  carry, offer, high five, sit, rock-paper-scissors shake, curl.

## The companion — the Claude Code mascot in pixel art

- **Silhouette** (`PixelMascot.swift`): an 18 × 12 terracotta body (#CC7A5D) with two tall slit eyes,
  stubby 3 × 4 arms and four 2 × 3 legs — 24 × 15 art pixels in all. The default name is still Patch;
  rename it in Settings › Characters.
- **Animation language**: the sprite moves, bobs and squashes smoothly while its eyes, arms and legs
  change in whole pixels, like hand-drawn frames. It breathes (a sub-pixel bob), blinks, glances, taps a
  foot now and then and gives a little bounce on the spot; it hops into celebrations with anticipation and
  a landing squash, wiggles in mid-air, sways while thinking and steps with alternating legs when it walks.
- **Eyes** in pixels: slits (open → half → closed line), happy ^ ^, focused dashes, worried, sleepy,
  wide, star (gold), heart (pink), closed ︶, off (grey). A mouth only appears for big feelings (grin, o,
  wavy).
- **Arms**: rest, slightly raised, diagonal, straight up — waving tips the raised arm out by a pixel —
  and a typing pose that reaches for the laptop and taps.
- **Claude's spinner**: while Claude works, the CLI's spinner (· ✢ ✳ ✶ ✻ ✽) spins in Claude orange over
  the mascot's head — the honest "Claude is working" signal, readable even at menu-bar size. It turns
  amber and steady while Claude waits for you, coral on errors.
- **Workstation**: it stands on a wide desk beside a small laptop whose screen shows only what the event
  says: code, terminal, docs, search, web, error, celebration, or Claude's `>` prompt — with an amber `?`
  while Claude waits for your answer. Subagents appear as tiny mascots hopping around it. When a script
  moves it off the desk it hops down to the floor and back up.
- **Menu bar**: the mini mascot is drawn at exactly 1 pt per art pixel on a roomy bar (¾ pt otherwise),
  snapped to device pixels so it stays crisp.
- **States**: absent, idle at desk, thinking, typing, reading, searching, watching a command, browsing,
  delegating, waiting (lock / … / ? bubble), detective (deerstalker + magnifier), rest (coffee), sleep
  (settles low, legs tucked), offline · arrive (drops in with a landing squash), setup, read task card,
  concerned (error board), celebrate, trophy, pack up, depart, greet, nod, wake up, stretch, sip, dance,
  show code, high five, catch, double take, pat, rock-paper-scissors.

## Accessories

Wearable by either character: party hat, cozy beanie, graduation cap, detective hat, festive hat
(December), witch hat (October–November), flower crown, round glasses, tiny headphones, developer hoodie,
knitted scarf. The mascot wears pixel-art versions of each. Unlocks are listed in Settings › Characters
with their exact criteria.

## Growing up

Mochi starts as a kitten (smaller, bigger eyes, a tuft of fur), becomes a young cat at friendship level 2
after 3 days of play or a week together, and grows up (full size, a little bell collar) at level 4 after 10
days of play or three weeks together. Friendship never decays, so Mochi never grows backwards. Turn it off
in Settings › Fun to keep the grown-up look.

## Asset specification (if you commission hand-drawn art later)

The renderers take a pose struct per frame (`PetPose`, `CompanionPose`), so artwork can be swapped
per part. A replacement set should provide, per character, layered vectors (PDF/SVG) for: body, ears/
bolts, arms (pivot at shoulder), feet/tail, each eye and mouth shape listed above, accessories aligned
to the same head anchor (pet head top at (0, −54), origin at the floor), and keep a 1.6–1.7 unit outline
weight so the 18 pt menu-bar silhouettes stay legible. The companion is pixel art defined in code (cells
per pose), so it needs no assets.

## A note on the mascot

The Claude Code mascot's design belongs to Anthropic. It is used here at the user's request in a personal
app; if you ever distribute MacTamagotchi, check Anthropic's brand guidelines first or switch the
companion back to an original design.
