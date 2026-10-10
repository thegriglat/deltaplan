# Build your own control bar

## What the game needs

Any USB HID joystick with two axes: stick sideways = roll, stick forward/back = pitch. The game reads the raw axes of the device; there is no custom protocol and no driver to install. Launch run and everything else stay on the keyboard.

Nobody has published a standard hang glider control bar controller; the closest found is a [DIY Arduino Micro controller for paragliding games](https://jpralves.net/post/2018/07/03/diy-controller-for-paragliding-games.html). So you build or buy a generic joystick board and wire your own sensors to it.

## Ways to build one

No step-by-step build here, only starting points.

- **Arduino Pro Micro or Leonardo** (ATmega32U4) with [ArduinoJoystickLibrary](https://github.com/MHeironimus/ArduinoJoystickLibrary). The board shows up as a game controller; the default axis range is 0-1023, so set it with `setXAxisRange` / `setYAxisRange`. A few dollars, one short sketch from the library examples.
- **STM32 "Blue Pill" with [FreeJoy](https://github.com/FreeJoy-Team/FreeJoy)**: no programming, you configure it in a desktop configurator. Up to 8 analog axes, calibration, smoothing and dead zone are done in the firmware. You need an ST-Link or UART adapter to flash it.
- A ready-made board such as Leo Bodnar BU0836 also works (analog inputs for potentiometers, no programming).

Sensors, one per axis:

- **Potentiometers** (linear or slider) are the simplest start; the contact wears out and the travel is limited by the mechanics.
- **[AS5600](https://www.infineon.com/assets/row/public/documents/24/49/infineon-as5600-datasheet-en.pdf)** (magnetic, contactless, 12 bit) can be programmed to a 18-360 degree angle, so a short stick travel can use the full range; needs a magnet on the axis.

The 10-bit ADC of an ATmega32U4 gives 1024 steps: over a 60 degree stick travel that is about 0.06 degree per step, enough for the game.

## Setting it up in the game

1. Plug the device in and start the game.
2. Open **Settings -> Controls -> Control bar / joystick**.
3. Pick your device in the device list ("first connected" uses whichever joystick is found first). If the chosen device is not plugged in, it is shown as not connected, there is no joystick input, and the mouse and keyboard keep working.
4. Choose the **roll axis** and the **pitch axis** (axis numbers as the system reports them; usually X, Y, Z, ... in that order, but check your board: wiggle the stick and watch the indicator).
5. Hold the stick in the neutral position and press **Set neutral**.
6. Press **Record range**, move the stick through its full travel in all directions, press the button again to stop. This stores the minimum and maximum of each axis, since a home-made sensor rarely gives exactly -1...+1.
7. Check the indicator: stick to the right must move it right, stick away from you must move it forward/up. If an axis goes the wrong way, tick the invert checkbox for roll or pitch.
8. Set the **dead zone** if the neutral position jitters. Keep **expo** at 0 (linear): a control bar has a real position, not a spring-centered stick, so a linear response is the honest one.
9. Press **Save**. **Reset** returns the calibration to the default (-1, 0, 1).

## Motion platform

If you also want to feel the flight, see [the motion platform output](../motion_rig/README.md).
