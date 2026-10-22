---
title: "Launch camp and the living world"
weight: 110
description: "Tents, gear, trampled grass and people at the launch; hay, geese, herds, aircraft and the charm on the control bar: what they are, when you see them and why they do not affect the physics."
---

# Launch camp and the living world

An empty slope with a launch pad would look wrong: real launches always have someone around, wings and bags lying about,
the grass trodden down. So every launch has a pilots' camp, and the world around it now and then does something: geese pass,
hay bales lie in the fields, an aircraft crosses high above. All of this is picture and sound. It does **not** affect the flight,
the air, the bots or the score (with one exception, the standing camp gear, described below).

## Tents

The camp has as many tents as there are pilots: yours plus one per bot (the "Other pilots in the sky" setting). In multiplayer
the number comes from the zone setting, so the camp is the same for every player.

Where they go:
- 30-50 m from the launch, behind it or to the side; not ahead of the launch line, not in the run-up corridor, and not more than 5 m below the launch down the slope;
- on level ground: slope no more than 8 degrees within 5 m, not on the edge of a drop;
- not on the trail to the launch, not near houses, not on roads and rivers, not in forest, water, on rock or snow, not on large stones and bushes.

If there is no level ground in that ring, the radius grows in steps of 60, 80 and 150 m. On a cliff or a steep slope there are no
tents at all: fewer tents, or none. Tents stand in a cluster, three types (dome, tunnel, tarp), six colors; the entrance mostly faces
downwind; each tent is tilted to follow the terrain.

A campfire burns near the camp; its smoke is carried by the model's local wind: a thin column in calm air, leaning at 3 m/s,
pressed down and trailing at 7 m/s. The other pilots wait their turn off to the side of the tents and gear.

![The camp from 25 m: tents, a wing, people and a pilot before the run](camp-view-25m.jpg "The camp from 25 m")

## Gear at the launch

Every launch pad has the gear of a flying trip lying and standing around: 2-4 assembled wings on the base bar with noses into the wind,
one half-assembled glider (tubes with the sail rolled up, the control bar on the ground), 3-6 bags, 2-4 backpacks with harnesses,
1-3 helmets, 2-5 bottles. The wings use the same models as the game. The set at a given launch is always the same: it does not depend
on the weather, the time of day, you or the bots. The nose and the ends of the base bar are placed on the ground using the model's
geometry, so on a slope the wing rests on the ground instead of hovering over it.

Tents, wings, the half-assembled glider and bags are obstacles: hitting them is a crash, like any obstacle. Helmets and bottles
are not obstacles.

## Trampled grass

Around the tents, near the gear, on the run-up circle and along the trail to the launch the grass is shorter, bent over and slightly yellower.
This is not for looks: on a slope tall grass used to hide the tents and the trail. At full trampling the grass is 12% of its normal height.
The value was chosen without measurements and checked by eye, so this is "plausible", not "as in real life".

## People

People stand, walk and wave near the camp: 3-8 of them, and they react when a pilot passes low nearby (within 150 m horizontally
and 60 m vertically). Up close (within 100 m) they are four different people with faces and everyday clothes
(two men, two women); the fifth and later ones repeat the first four. Farther away they are simplified figures in the colors of their
clothes; beyond the visibility limit nobody is drawn. At most 8 people are fully animated at once, the nearest first.

![A person at the camp from 5 m: raised arms, T-shirt and jeans](camp-person-5m.jpg "A person at the camp from 5 m")

Where the simulator lies: the walk cycle is built for about 1.1 m/s, but the people move at 0.05-0.2 m/s, so stepping in place slides
more than in real life. The palm during a wave faces wherever the arm's arc carries it. Distant hair is a single color.

![Gear at the launch from ground level: a bag, control bars, wings in the distance; some models in the frame are black](camp-view-45m.jpg "Gear at the launch")

## Footsteps and the rustle of grass

On the ground, while running and walking, you hear steps on grass or gravel; breathing builds up over 4 seconds of running, and
after stopping or landing you pant. Separately there is a rustle of feet against grass: louder the faster the feet move over the ground
and the deeper they sink into the grass. It is an honest cue that the ground is close at takeoff and landing, with no indicators.

## License of the people models

The people are [Microsoft Rocketbox](https://github.com/microsoft/Microsoft-Rocketbox) models (Male_Adult_06, Male_Adult_10, Female_Adult_12,
Female_Adult_17), MIT license, (c) 2020 Microsoft. We reworked them: reduced levels of detail, a lighter skeleton,
512-pixel textures, retargeted animations. The license text sits in the game next to the models; the asset list is in `ASSETS.md`
in the repository.

## The living world

Scenes around you appear depending on the place, date and weather of the flight; the schedule does not depend on the frame step, and for the
same world key (place and dates) the same things repeat. Many occur in almost every flight when the place, weather and time of day allow;
geese and aircraft are rarer.

| Scene | What it is | When you see it |
|---|---|---|
| Hay bales | Round bales on meadows and fields: in rows across the field and in piles at the edge | Summer and autumn, by flight date |
| Wedges of geese | A flock in a wedge, honking is audible | Heading north in spring and south in autumn (reversed in the southern hemisphere); no geese out of season |
| Charm on the control bar | A seagull figure on a cord in the right corner of the bar; swings with rolls and turbulence | Always |
| Herds | Sheep, cows or horses; they scatter if you fly close | In the warm season |
| UAZ off-road | One or two vehicles with a dust trail | Where a suitable valley exists |
| An-2 | An aircraft passes low over the terrain, its sound is audible | In the warm season, by day, in moderate wind |
| Airliner | A high aircraft with a contrail, which lasts longer in humid air | By day and at dusk |
| Balloons | One balloon or a festival group | Morning and evening, in light wind, in the warm season |
| Eagle | Overtakes you off to the side in a thermal or near rocks | By day |
| Group of hang gliders | Other pilots on a neighboring slope | By day, in moderate wind |

The conditions in the table are in general terms; exact thresholds are in the game configuration.

### What this does not change

These scenes are only drawn and heard: they have no physical bodies, no collisions, no entries in the obstacle map or the bot data,
no hints and no text. The game's test checks that a flight with and without the scenes is bit-for-bit identical: physics, air, bots,
collisions, score and result. You can fly through the An-2 and nothing happens. Each scene can be switched off by a flag in the game configuration.

### Limits

- Geese, aircraft and balloons are scenery, not data: they do not show wind at altitude and do not mark thermals, although balloons drift with the wind.
- The eagle appears near rocks and thermals of the model (lift of at least 1 m/s), but that is a "looks like lift" hint, not a measurement.
- Hay, herds and the UAZ are placed on fields, meadows and off-road ground by land-cover data; with inaccurate data they may end up
  somewhere that is not a real field.
