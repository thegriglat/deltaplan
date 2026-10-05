---
title: "Deltaplan 0.8.0"
date: 2026-09-29
description: "Multiplayer: fly with friends in the same sky — shared weather, thermals and clouds."
cover: screenshots/01_сетевая_игра_рядом.jpg
---

# Deltaplan 0.8.0 — multiplayer

29.09.2026. {{< button href="https://thegriglat.itch.io/deltaplan" >}}Download on itch.io{{< /button >}}

## What's included

**Multiplayer**

- "Multiplayer" in the main menu: fly together with friends in the same sky. "Create" — pick a place, the game gives you a
  4-digit code; "Join" — enter the code. The world (place, date, time, weather, thermals and clouds) is the same
  for everyone.
- At home on one network: leave the "Server" field empty — the zone is created right on this computer; for the others it
  appears in the "Nearby" list by itself, and joining takes a single Enter key. To play over the internet, enter the address of your own server
  (a Go server in the server/ folder, started with a single line in Docker).
- The host is the first to join; if they leave, the next one becomes host and nobody notices. The zone closes
  when everyone has left.
- "Catch up" — the `=` key: a list of pilots over the flight, Enter — the wing smoothly (≈10 s) flies to
  the selected pilot over the terrain and hands control back. If a friend is already in the air, you catch up
  with them right away when you enter the zone. After landing or a crash, the result window offers "Continue nearby" or "Back to launch".
- Launch queue: live pilots first, then bots; if you stay first for more than a minute, you go to the back; after landing,
  a crash or an aborted launch — also to the back of the queue.
- Bots in the zone: as many as the creator set in settings; the host drives them, the others see the same bots.
- Settings → "Pilot name" — others see it above your wing.

**Flight and weather**

- Every "Fly" is a new day: thermals and clouds are placed anew with the same weather; "Again" — the same
  day.
- Thunderstorms are rare: at +26 almost never, at +30 — about one flight in three somewhere in view, at
  +34 — more often; wind from thunderstorms is no more than 13 m/s.
- Half of the other pilots are already in the air ahead of the launch when the flight begins (so being first is not boring), the rest
  take off after you.

**Other**

- Own icon and splash screen at startup; the name Deltaplan; settings are now in the Deltaplan folder
  (`~/.local/share/Deltaplan`, `%APPDATA%\Deltaplan`), the old ones are moved automatically on first launch.
- No banding on sky and haze gradients; shaders are built in advance — the first launch is faster and there is less
  stutter at the start of a flight.

## Screenshots

{{< gallery "screenshots/0[1-7]*" >}}

![Flight through own server in Docker](/releases/0.8.0/screenshots/08_через_сервер_docker_вижу_колю.jpg "Flight through own server in Docker")

Devlog text for itch.io (in English) — [devlog](https://github.com/thegriglat/deltaplan/blob/main/site/content/releases/0.8.0/devlog.txt).
