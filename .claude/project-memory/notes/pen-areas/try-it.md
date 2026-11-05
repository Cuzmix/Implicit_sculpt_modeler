# Try it: the pen by where it points

Everything below passed the desktop simulation only. None of it has been tried with a real pen yet. Settings live in **Settings > Pen > Where the pen points**.

## iPad with Apple Pencil Pro (roll, double-tap, squeeze)
1. Hover over the model and roll the pencil slowly. Past the first 10 degrees, the view twists about the point under the tip, and that point stays put. The hint reads "Twist N°". Near level it should hold level for a moment.
2. Move across the model while turning the pencil a little. Nothing should twist, because the count starts again every 40 points.
3. Hover over empty space and roll. It twists about the tip. Try setting Roll over empty space to Zoom toward the tip.
4. Grab or Elastic: drag, then roll while still holding. What you hold should turn. With symmetry on, the mirrored side turns the mirrored way. The drag and the turn are one undo step.
5. Roll over each place in the interface:
   - The shelf turns pages, one every 40 degrees.
   - Undo/Redo scrubs History, one step every 20 degrees.
   - The navigation head spins the view.
   - The colour Disc turns the hue.
   - A slider or the brush values changes the value.
   - A choice or a row of tabs steps through it.
   - A Settings panel scrolls.
6. Double-tap in each place:
   - Over the model it follows the iPad setting.
   - Empty space frames the model.
   - The shelf opens the brush picker.
   - Undo opens the History panel.
   - The navigation head resets the camera.
   - The Disc swaps the colours.
7. Squeeze over a panel. By default it does what it does over empty space.

## Android or Windows pen (side and second buttons)
1. Press the side button over the model: the brush pie opens. Then set **Side button** under Over empty space to something else, such as Frame, and press it over empty space.
2. Set **Second button** under Over empty space to Wireframe. Pressing it over the shelf or a panel should toggle wireframe. Over the model it should still act as the middle button.
3. If your pen reports roll (some Windows pens do), try steps 1 to 5 from the iPad list.

## What to tell me
- Whether 10 degrees to engage feels right, or too easy or too hard to trigger by accident.
- Whether the roll steps (40 degrees per page, 20 per History step, 30 per choice) feel right.
- Anything that triggered when you didn't mean it to.
