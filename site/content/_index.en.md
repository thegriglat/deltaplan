---
title: Deltaplan
---

# Deltaplan — a hang glider simulator

Deltaplan is an open-source free-flight hang gliding simulator for Windows, Linux and macOS.
It is made for those who already fly and want to fly once more at home, and for those who are simply curious what it is like to
fly a wing in a thermal over real terrain. The game has weight shift, weather from a forecast the pilot sets, thermals, slope and rotor wind, real places from maps and 48 wing models with parameters from datasheets. It is a simulator with simplifications: where exactly it differs from real flight is in the "What the game does not do" section below.

## Features

- [Flight and controls](/mechanics/flight/) — weight shift like on a real wing, the launch run, stall and crash
- [Wing models](/wings/) — 48 wings in four groups: prototype, sizes, masses and where each number comes from
- [Slope wind](/mechanics/air-model/wind-phases/) — airflow over terrain, separation and rotor behind a ridge, calm and evening drainage; the simple mode is ["Heuristic"](/mechanics/air-model/heuristic/)
- [Thermals](/mechanics/air-model/thermals/) — strength and frequency by time of day, the edge, dry thermals
- [Weather](/mechanics/weather/) — temperature, wind and cloud cover from a forecast the pilot sets; thunderstorms
- [Clouds](/mechanics/clouds/) — cumulus, cumulonimbus, cloud shadows
- [Terrain](/mechanics/terrain/) — real places from maps
- [Lift cues](/mechanics/visual-cues/) — birds, dust, grass in the wind
- [Instruments](/mechanics/instruments/) — variometer, tablet on the control frame
- [Bots](/mechanics/bots/) — other pilots at launch and in the air
- [Multiplayer](/mechanics/multiplayer/) — flying with friends in the same sky
- [Air model](/mechanics/air-model/) — a physical air field: wind at terrain, thermals from the field, turbulence

Controls are keyboard, mouse and gamepad, as well as a two-axis USB joystick as a home-built control frame; during the launch run the wing's nose holds itself.

## What the game does not do

- The air is a model, not a measurement: the wind field is computed as an hourly mean, and the position of each thermal is statistics. There is no moisture in the field, clouds come from the weather model. The nocturnal low-level jet is not reproduced; calm and evening drainage are the weakest spots. The speed-up at the brow is underestimated by 15–20 %, wind in a saddle is stronger than in real life, and behind a ridge in strong wind turbulence is 3–4 times stronger than in the literature.
- The wing: no sideslip and yaw as a separate degree of freedom, pitch is simplified. For many of the 48 wings the sail shape, twist and profile are taken from the class base model, because the datasheets do not contain these numbers; on each wing page every number is marked with where it comes from.
- There is no tuning "so that it feels right": what was checked against measurements and what did not match is on the [Approaches and results](/approaches/) page.

## Screenshots

![Chase view in flight over Altai](/docs/screenshots/gameplay/chase.jpg "Chase view in flight over Altai")

![Cockpit view](/docs/screenshots/gameplay/cockpit.jpg "Cockpit view")

![A pilot flying over a valley, the launch below](/docs/screenshots/site/01_в_термике.jpg "A pilot flying over a valley, the launch below")

![A wing at the base of cumulus clouds](/docs/screenshots/site/04_у_кромки_облаков.jpg "A wing at the base of cumulus clouds")

![Launch: a wing on the slope, another pilot on the launch run](/docs/screenshots/site/03_разбег.jpg "Launch: a wing on the slope, another pilot on the launch run")

![Slavutich-UT from behind over a slope](/docs/screenshots/site/05_славутич_ут_сзади.jpg "Slavutich-UT from behind over a slope")

## Download

{{< button href="https://thegriglat.itch.io/deltaplan" >}}Download on itch.io{{< /button >}}

## Latest version

{{< latest-release >}}

All versions are on the [Releases](/releases/) page.

## Open source

Deltaplan is an open-source project ([github.com/thegriglat/deltaplan](https://github.com/thegriglat/deltaplan)).
It is made for pilots and for those who want to find out what flying a hang glider is like.

## Where the idea came from

The author's parents are hang glider pilots, and this gave the project its start.

## Acknowledgements {#acknowledgements}

Thanks to [DHV](https://www.dhv.de) (Deutscher Hängegleiterverband) for the open data of wing datasheets and type tests:
the datasheets, geometry and characteristics on which the wing configs and 3D models in the game are based.
The result is the [Wing models](/wings/) section: 48 wings with data and a mark of where each number comes from.

## Sections of the site

- [Mechanics](/mechanics/) — how the game works: flight, atmosphere, terrain, multiplayer
- [Wing models](/wings/) — all the game's wings by group: prototypes, sizes, masses, origin of the numbers
- [Releases](/releases/) — what is new in each build, with screenshots
- [Approaches and results](/approaches/) — which ways of computing wind, thermals, wings and world data were tried, what came out and what is in the game now
- [Research](/research/) — where the game's numbers and models come from: surveys, prototypes, computational experiments
- [Diary](/diary/) — the development diary: the decisions of the day and why
- [Module documentation](/docs/) — technical documentation of the game's modules
