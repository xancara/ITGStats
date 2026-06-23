# ITGStats

Jump to [/module/README.md](https://github.com/xancara/ITGStats/blob/main/module/README.md) for instructions

---
### A twitch extension and module for ITGmania 1.2.1+ and SimplyLove 5.8.1+

<img width="952" height="668" alt="ITGStats-Screenshots" src="https://github.com/user-attachments/assets/c6541521-02ec-403a-b9b9-9b8c0fed710a" />

---

***ITGStats*** adds a small, unobtrusive **"ITG Stats" pill** in the corner of the stream.
Clicking it opens a panel with everything that happened in the current session - viewers
can browse it at their own pace without interrupting the broadcast. When you aren't in an
active session the overlay hides itself completely, so it never clutters your layout.

**Session view** - for each active player (P1, P2, or both):

- The list of songs played this session: title, artist, difficulty, meter, and rate mod.
- The score on each song (ITG percent and **EX score** when EX scoring is on), letter
  grade, restart count, and notes hit / total.
- Live "▶ playing" status on the song in progress, updating as you play.
- Session totals: songs played, average score, total notes hit, and session duration.
- Supports Singles and Doubles for stats layouts and knows when the player switches between them.

**Per-song detail** - viewers click any completed song to see the full Simply-Love-style
evaluation, reproduced faithfully:

- **Judgment totals** with the FA+ split - blue Fantastic (Fa+) and white Fantastic (Fan)
  shown separately, then Excellent / Great / Decent / Way Off / Miss, in Simply Love's
  colors.
- **Timing stats** exactly as SL's evaluation header reports them: mean absolute error,
  mean (signed) error, standard deviation ×3, and max error.
- **Offset histogram** - the per-tap timing distribution, binned to 1 ms like SL.
- **Density · scatter · life** graph - chart NPS per measure with the judgment scatter and
  your life-meter line overlaid (including the fail point if you died).
- **Per-arrow judgment breakdown** - W0–W5 / Miss per column, early-hit markers, and
  misses-because-held, mirroring SL's per-column pane (4 panels for singles, 8 for doubles).
- The **stream breakdown** and the **modifiers** you used.

**Multiple profiles** - if you enable profile names (see options), each profile that
submits scores gets its own tab, so a guest's scores don't get mixed with yours. With four
or more profiles the tabs become a dropdown.

The overlay automatically follows the viewer's Twitch **light/dark theme**.


## Current Roadmap
---
## ITGStats v0.2.0

**Bug Fixes**
* **Live Updates:** Fixed an issue where the ITG score displayed during live updates while "Display EX score" was enabled. This is already fixed in the module just not on the display side.

**Enhancements**
* **Average Score:** Excluded 0.00 scores from the calculated average score.
* **Step Counts:** Notes hit during restarts are now properly added to the session's total step count.
* **Autoplay Detection:** Added an autoplay label/indicator (dimmed UI) to the session list.

**Extensions**
* **Panel Extension:** The panel module now renders immediately rather than requiring the Pill.
* **Mobile Extension:** Added mobile support, implementing minor UI tweaks to ensure mobile friendliness.

---

## ITGStats v0.3.0

**New Features**
* **Tournament Mode:** Aggregate multiple machines (via `machineID`) and channels into a single, unified stat stream. Data persists for a set duration based on the registered Tournament API key (Channel key is still required).
* **Course & Marathon Support:** Comprehensive tracking for grouped song bundles. 
    * Calculates and displays individual "Live Derived" scores for each song within a course using live judgment data.
    * Tracks and displays the cumulative "Course Score" at the start and end transition points of each song.
    * Visually groups related songs together under the parent course data.
