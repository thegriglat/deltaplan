---
title: "Bots and the start queue"
weight: 80
description: "Other pilots in the sky: how bots fly, where their names come from and how the start queue works (in single-player and online)."
---

# Bots and the start queue

Besides the pilot themselves, "other pilots" — bots — fly in the sky. They are not tied to a route, they just fly: look for thermals, soar the ridge, hop from one target to another. Half of them are already airborne when the flight begins — the sky is not empty from the first second. In online play everyone sees the same bots, and a shared queue forms at the launch: live pilots first, then bots.

## Who the bots are

The number of bots is the "Other pilots in the sky" setting, 0–20 (`bots.count`, default 4, takes effect from the next flight). Each bot has its own wing (random from the list `configs/bots.json → wings`, all about equally likely; Soviet wings are rare in the sky — only the "Apogey"), a pilot mass of 65–95 kg and a sail colour from a brand-free palette (red, orange, yellow, green, turquoise, blue, violet, crimson, graphite). All parameters come from the flight seed (`configs/bots.json → seed`, mixed with the launch site), so the same flight (same site, same seed) gives the same bots.

The flight model of the bots is the same as the player's — `FlightModel` and `Atmosphere.air_velocity_at` — only the physics step is less frequent when the bot is far away: 30 Hz near the player (< 1500 m) and on the ground, 10 Hz farther, 4 Hz beyond 4000 m.

### How the bots fly

The bot's "brain" is `BotPilot` ([scripts/game/bot_pilot.gd](/scripts/game/bot_pilot.gd)), the same class as the route bot in the route-passability studies (docs/plan/atmosphere). The bot "feels" only what a live pilot has access to: variometer, altitude, AGL, heading, bank, position, ground speed — it does not peek at the atmosphere's thermal map (`thermals_near`). Flight modes:

- **CRUISE** — transition by the MacCready calculation;
- **ENTER** — the averaged variometer is above the threshold (0.5 m/s over its own sink rate; in "rescue" mode below — 0.3 m/s) → a 35–40° turn toward the side where the lift was;
- **CIRCLE** — centring the thermal by the Reichmann rule (stronger lift — flatter turn, weaker — steeper, the circle shifts toward the maximum), bank 8–50° (nominally 38°), the lift map is remembered for 12 s;
- **PROBE** — checking the thermal's side after "touched it and lost it";
- **RIDGE** — "figure eight at the slope": two adjacent turns over one working point, the turn is always from the slope toward the valley; it engages if the headwind at launch is ≥ 4 m/s, soars for 60–300 s (random) or until it has gained 250 m above the launch, then leaves for glides; below 25 m AGL it leaves the slope for the valley;
- below 300 m AGL — "rescue" mode: minimum sink speed, takes any lift, the entry threshold is lower than usual.

Without a target ("other pilots in the sky", class `WanderPilot`, [scripts/game/wander_pilot.gd](/scripts/game/wander_pilot.gd)) the bot hops between random points within a circle of 3500 m radius around the launch (a glide of 800–2500 m, the first — 1200 m from the slope into the valley along the launch heading); if enabled in the config, the glide target is chosen under a growing cloud in a ±30° sector from the heading, as a pilot reads the sky. In one thermal everybody circles in the same direction — it is set by whoever entered first (this may be the player too): circles closer than 300 m to the centre of an "occupied" thermal within the last 60 s count as the same thermal.

Bots keep apart from each other and from the player by a closure forecast (`configs/bots.json → separation`, checked 4 times a second): no closer than 50 m horizontally and 15 m vertically to each other (forecast 12 s ahead), no closer than 90 m horizontally and 30 m vertically to the player (forecast 20 s) — there are no collisions of bots with the player in the game at all. Below 25 m AGL (launch run, landing) separation is not applied — the ground is busy there anyway.

### Names above the bots

Above each bot there is a name tag (`NameTag`, a Label3D billboard): constant size on screen (22 px at a window height of 1080, further — proportional to FOV), fully visible up to 250 m, fading out by 900 m (on the ground — already by 120 m, so it does not flicker at the launch), not visible behind terrain (the tag writes depth). The names come from `configs/bot_names.json`, a separate pool for each interface language (ru, en), with no repeats within one flight, the order is from the flight seed; when the language is switched, the bots immediately take names from the new pool in the same order. The "Pilot names" setting (`bots.names.show`, on by default) applies at once, even from pause.

![Names above the bots](/releases/0.7.0/screenshots/119_имена_ботов_ru.jpg "Names above the bots (Russian language)")

The setting in the "Settings" screen:

![The "Pilot names" setting](/releases/0.7.0/screenshots/121_настройки_имена_пилотов.jpg "The \"Pilot names\" setting")

## Half are already in the air

If all the bots were put in the start queue behind the player right away, being first to fly into an empty sky would be boring. So half of the bots (rounded down, but at least one — with a single bot, it is the one in the air) are already circling ahead of the launch by the start of the flight: {{< commit 0e07d62 >}}. They appear 250–700 m ahead of the launch along the launch-run heading, up to 300 m to the sides, 200–450 m above terrain in height (and not lower than the launch plus this margin), with a heading ±60° from the launch heading — random, but deterministic (flight seed). The other bots wait in the start queue behind the player and take off after his lift-off.

## Start queue {#start-queue}

The bots waiting on the ground stand with their wing on level spots behind the launch — not in the player's launch-run corridor, not near rocks, bushes and trees ([scripts/game/bot_pilots.gd](/scripts/game/bot_pilots.gd) → `find_spots`): a grid search with a 3 m step, spots no steeper than 8° (if not enough — 14°, then any), no closer than 12 m to each other (wingspan ~10 m) and no closer than 9 m to the player. While the player is on the ground the bots wait; after his lift-off the bots come to the launch one at a time every 30 s (`launch.interval_s`) and run with the same mechanics as the player (`BotAgent`). If it landed short or crashed, the bot stands for a minute (`landed_stand_s`), then is removed and joins the queue again.

In online play the queue is shared by live pilots and bots ([scripts/game/net_queue.gd](/scripts/game/net_queue.gd), NET-43): the waiting places are the same as for the bots in single-player (place 0 is the launch itself), but the rules are like a live queue at a real launch:

1. **Live pilots first, then bots.** A live pilot who returns to the queue stands in front of the first bot (except a bot that is already walking to the launch or running first — it is not shifted).
2. **Only the first may run.** For the rest the launch run is blocked until they become first; once one has taken off, the next steps forward.
3. **Stood first for more than a minute — to the back.** So that nobody holds up the whole queue by getting stuck in place.
4. **After a landing, a crash or an aborted launch — to the back of the current queue** (in front of the bots; if the queue is empty — straight to first). This is deliberate: a light penalty for a failed launch and a live queue, as at a real launch — not a "bug to fix".
5. There are no ways around the queue: if the queue is in the way, the solution is to create an online zone without bots (0 in the settings) and take off one after another.

The queue is run by the zone leader (not to be confused with a "senior" in the everyday sense — this is the one who technically holds the clock and broadcasts `ZoneState.queue` once a second): it does not ask the other clients, but sees their phases itself (standing/walking near the launch — in the queue; running — in the queue, do not touch; in the air, on tow, landed, crashed or gone farther than 250 m from the launch — out of the queue). Each client walks to its own place by its number in the queue; when the leader changes, the new one continues from the last broadcast queue, and the timer of the first one's idle time starts over.

![The start queue](/releases/0.8.0/screenshots/07_очередь_на_старт.jpg "The start queue in an online zone")

## Limits of the model

- There are no collisions of bots with the player at all (separation only "on paper" — by the closure forecast); bot-bot collisions were not checked separately, the separation is the same 50 m/15 m.
- Bots formally have no landing: touching the ground is neither a crash nor a full landing, but a pause of a minute with subsequent placement in the queue.
- Going around terrain sideways and real manoeuvring between several thermals at once are not modelled — only entry/centring/exit by the variometer, like an honest route bot (without peeking at the thermal map).
- The "figure eight at the slope" engages by a single threshold — headwind at launch ≥ 4 m/s; crosswind and tailwind at launch are not taken into account separately.
- There are deliberately no ways around the queue (see above) — this is a game decision, not an oversight.

## What was considered and why this way

- **All bots in the queue from the very start** — rejected: being first to fly into an empty sky is uninteresting, so the "already in the air" half was added ({{< commit 0e07d62 >}}).
- **Priority entry without a queue** ("catching up" with a friend without waiting for the launch) — implemented separately as the ["Catch up"](/mechanics/multiplayer/) mechanic, not as a way around the start queue: the start queue itself has no exceptions to its rules.
- **A real landing for bots** (with a flight incident, a debrief) — not done: a pause of a minute after touching the ground is simpler and does not require landing-approach logic from the bot.

## More

- [docs/guide/game.md](/docs/guide/game.md) — the "Other pilots" section and the command line (`--bots=<N>`, `--look-at=bots`).
- [scripts/game/bot_pilots.gd](/scripts/game/bot_pilots.gd) — bot management: spawning, the queue at the launch, `_start_airborne`.
- [scripts/game/bot_pilot.gd](/scripts/game/bot_pilot.gd) — the bot's "brain": modes, centring, figure eight at the slope.
- [scripts/game/wander_pilot.gd](/scripts/game/wander_pilot.gd) — flight without a target ("other pilots in the sky").
- [scripts/game/net_queue.gd](/scripts/game/net_queue.gd) — the start queue online (NET-43).
- [configs/bots.json](/configs/bots.json), [configs/bot_names.json](/configs/bot_names.json) — all the numbers and the name pool.
- [docs/plan/multiplayer.md](/docs/plan/multiplayer.md) — items 6–7 (bots and the queue in online play).
- {{< commit 0e07d62 >}} — half of the bots already in the air at the start of the flight.
