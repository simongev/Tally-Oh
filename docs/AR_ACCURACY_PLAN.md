# AR Target Accuracy — Investigation & Plan

**Goal:** targets rendered in AR sit exactly on the real aircraft/airport, in every scenario:
on the ground or in flight, ADS-B or internet, pressurized or unpressurized, slow/low or fast/high,
camera facing any direction.

**Product constraint (owner decision):** the app is instant and automatic. The user lifts the
phone, sees where the traffic is, and puts it down. Sessions are seconds long, and there is **no
manual alignment anywhere** — if the user has to trim the AR, the app has failed. Every correction
below must be learned and applied without user input.

This document is the investigation result and the implementation plan. No code has been changed yet.

---

## 1. What actually determines whether a marker sits on the real target

The marker is drawn along a **direction** (azimuth + elevation angle) from the camera. Distance is
compressed onto a 5–80 m shell, so *only angular error matters*. The direction is computed from five
independent chains, and the total miss is the sum of their errors:

| # | Error chain | Contribution | Reference numbers |
|---|-------------|--------------|-------------------|
| 1 | **Target position** (data source, latency, dead reckoning) | azimuth + elevation | 8 s of un-compensated motion at 450 kt = 1.85 km; at 5 NM that is a ~11° azimuth miss |
| 2 | **Ownship position** (which GPS, extrapolation between fixes) | azimuth + elevation | 250 m position error at 2 NM target range = 3.9° |
| 3 | **Ownship & target altitude frames** (baro vs geometric) | elevation | 500 ft frame mismatch at 2 NM = 2.3° above/below the real aircraft |
| 4 | **Azimuth alignment** (ARKit world north vs true north) | azimuth, all targets equally | cockpit compass error of 10–30° is common; 10° ≈ 15 % of the iPhone camera's horizontal FoV |
| 5 | **Render-time geometry** (update cadence, camera-relative math) | both | already solved to < 0.1° by the 60 Hz tick + camera-relative shell |

For "exactly where they are" the budget is roughly **≤ 1–2° total**. Chains 1, 2 and 5 are already
in good shape on `main` (dead reckoning both sides, `seen_pos` decoding, 60 Hz repositioning).
Chains **3** and **4** are where the remaining error lives, plus a set of correctness bugs in the
ADS-B path (chain 1/2) found during this investigation.

### The lift-and-look clock

Because a session is a few seconds long, accuracy is only worth what it is **at second one**. Every
correction below is therefore judged on two axes, and a fix that is accurate but slow to converge is
a failed fix:

| Budget | Target | What it constrains |
|---|---|---|
| Time to first usable frame | **< 2 s** from lift | ARKit init/relocalization, first GPS fix reuse, data already in memory |
| Time to best achievable accuracy | **< 2 s**, ideally immediate | corrections must be *carried over* between lifts, not re-learned each time |
| User actions required | **0** | no calibration gesture, no trim, no prompts |

This reframes the azimuth problem: the goal is not just a corrector that converges, but one whose
result **persists across lifts**, so the second and later glances start already correct.

### What is already right on `main` (validated, keep as-is)

- Camera-relative positioning (markers don't drift to the AR origin as the aircraft flies).
- Dead reckoning of targets (with `seen_pos` server-side age) and of ownship, 60 Hz tick.
- Magnetic-declination correction for ARKit's `.gravityAndHeading` magnetic-north alignment
  — **field-tested and confirmed** (~10–15° improvement, build 271).
- No ARKit session restarts *from heading-accuracy changes* in flight; ground-only recalibration
  popups. (Foreground/appear still resets — see F6.)
- Relaxed in-flight GPS accuracy gate (500 m), stale-target dashed rings, coast caps.

### What was already tried and failed (do NOT repeat)

- **Camera-bearing-vs-compass residual correction** — tried continuously (build 113) and
  one-shot (build 274). *Both* made accuracy worse in field tests and were reverted. Any new
  azimuth auto-correction must use a different measurement principle, and must ship
  **log-only** until flight data proves it converges (see P3).

---

## 2. Findings (ranked by impact)

### F1 — GDL90 frames are parsed without byte-unstuffing or CRC *(ADS-B scenarios — high)*
`processGDL90Data` splits on `0x7E` flags and parses payloads directly. GDL90 is a byte-stuffed
protocol: any `0x7E`/`0x7D` inside a message is transmitted as `0x7D` + (byte XOR 0x20), and every
frame ends with a CRC-16-CCITT. The code never un-stuffs and never checks the CRC. Statistically
**~20 % of 30-byte traffic frames contain at least one escaped byte** — those parse with corrupted
latitude/longitude/altitude (position jumps) or fail the length guard and are dropped. Corrupted UDP
datagrams are also accepted silently.

### F2 — Ownship dead reckoning mixes phone-GPS and ADS-B state *(ADS-B in flight — high)*
`ARSceneManager.deadReckonedUserLocation()` extrapolates `liveUserLocation` using
`liveUserSpeedKt/Course/Timestamp`. But there are two competing writers:
- `updateUserVelocity(...)` — **phone GPS only** (position, speed, course, *phone* timestamp);
- `updateAircraft(userLocation:)` — the 4 Hz tick, which overwrites the position with the **ADS-B
  ownship** coordinate but *not* the timestamp/velocity.

Result in ADS-B mode: a fresh ADS-B position is extrapolated by the elapsed time since an *older
phone fix* (double-counting up to ~0.25–1 s of motion → 30–130 m at cruise speed), using the
*phone's* course — and if the phone GPS is gated out entirely (deep fuselage), speed/course go stale
and dead reckoning runs on garbage. ADS-B ownship reports (1 Hz, with their own ground speed and
track) are never used for extrapolation between reports.

### F3 — Altitude reference frames are mixed *(all scenarios — high; the "pressurized or not" problem)*
Three altitude frames are in play and are currently compared across frames:

| Source | Frame | Notes |
|--------|-------|-------|
| Target `alt_baro` (adsb.lol) / GDL90 traffic altitude | **pressure** (29.92 inHg standard) | from the target's own static system — always valid *in its frame* |
| Target `alt_geom` (adsb.lol) | **geometric** (WGS-84 HAE) | currently used only as a *fallback*, backwards |
| Phone GPS altitude | **geometric** (MSL; `ellipsoidalAltitude` gives HAE) | `verticalAccuracy` never checked |
| Phone barometer (CMAltimeter) | **cabin pressure** | ≈ outside static only in an *unpressurized* cabin |
| GDL90 0x0A ownship altitude | **cabin pressure** (Sentry's internal baro) | wrong by 20,000+ ft in a pressurized jet |
| GDL90 0x0B ownship geometric altitude | **geometric** | **currently discarded** (`case 0x0B: break`) |
| Airport elevation (CSV) | **geometric** (MSL) | compared against *pressure* altitude in ADS-B mode today |

Concrete failures today:
- **Internet in flight:** user altitude = GPS geometric, target = `alt_baro` pressure. QNH/temperature
  deviation from ISA routinely puts these 300–1,500 ft apart → 1–7° elevation error on nearby traffic.
- **ADS-B in a pressurized aircraft:** ownship 0x0A is *cabin* pressure altitude (e.g. 8,000 ft cabin
  at FL350) vs target's real pressure altitude → tens of thousands of feet of error. The geometric
  0x0B message that would fix this is thrown away.
- **Airports in ADS-B mode:** MSL elevation vs pressure altitude → hundreds of feet of error on
  non-standard days.
- **Unpressurized + ADS-B** is the one combination that is currently frame-consistent (and it is
  genuinely the most accurate option — both sides on the same 29.92 reference).

### F4 — Azimuth alignment has no in-flight correction path *(all flight scenarios — high)*
ARKit `.gravityAndHeading` samples the magnetometer **once at session start**; that instant's cockpit
magnetic error (steel, magnets, avionics — commonly 10–40° in a cockpit) becomes a session-long bias
on *every* target. Afterwards ARKit holds orientation by visual-inertial odometry, which in a moving
aircraft drifts additionally (vibration, IMU sensing aircraft accelerations the camera doesn't see,
gravity reference tilting in sustained turns). This matches the reported *"accuracy changed while I
was moving the phone around"* — that is VIO yaw wander, not compass recalibration (the declination
term used in placement is a lookup-table difference and is stable by construction). Two automated
corrections have already failed field tests (see above), so today a session anchored on a bad compass
sample stays wrong for as long as it runs — and (see F6) it re-anchors on a *fresh* bad sample every
time the user lifts the phone.

### F5 — The heading readout and 2D map use the raw compass *(cosmetic but trust-destroying)*
Marker placement never uses `userHeading` (bearings come from GPS), but the HUD "🧭" line and the 2D
map orientation do. In a cockpit the compass is often wrong while placement is fine — exactly the
user's observation (*"accuracy was not bad, but the compass showed the wrong direction"*). The app
should display the heading the *placement pipeline* effectively uses, not a number it ignores.

### F6 — Every lift re-anchors the AR world on one fresh compass sample *(the lift-and-look killer — high)*
`startARSession()` runs `session.run(config, options: [.resetTracking, .removeExistingAnchors])`, and
it is called from `viewWillAppear` **and** from the `appWillForeground` notification. In the intended
usage — lift the phone, look, put it down, lift again ten minutes later — that means **every single
lift throws away the world and re-locks north to whatever the magnetometer reads in that instant**,
inside a cockpit, with the phone still moving from being raised. Consequences:

- Nothing learned during the flight survives: lift #4 is no better aligned than lift #1, and each
  lift draws an independent sample from the cockpit's error distribution — so accuracy visibly
  *changes between lifts* (consistent with the reported "it changed while I moved the phone").
- The first ~1–3 s after each lift are also ARKit's `.limited(.initializing)` window, exactly the
  seconds the user is looking. A short session spends most of its life in the worst tracking state.
- Resetting discards the cockpit-interior feature map that ARKit could otherwise relocalize against.

For a long AR session this design is defensible; for a 5-second glance it is the single most costly
decision in the app. P3.4 addresses it directly.

### F7 — The sky can be empty for the first seconds of a lift *(lift-and-look — high)*
Accuracy is worthless if there is nothing drawn. While the app is suspended in the user's pocket, no
timer fires: no internet fetch, no cleanup. On lift, several things unwind in an unhelpful order:

- The 90 s staleness cleanup fires on resume and **deletes every aircraft** if the pocket period
  exceeded 90 s — so the scene starts empty rather than stale-but-useful.
- `ensureInternetFetchRunning()` early-returns whenever the fetch timer object still exists (it is
  never invalidated on background), so foregrounding does **not** force an immediate fetch; the app
  waits for the resumed 8 s timer plus network latency.
- Target dead reckoning coasts only 20 s, so even surviving aircraft are frozen at their coast cap.

The result is that the *first* few seconds of a glance — the entire session, in the intended usage —
can show an empty or frozen sky, then pop into correctness right as the user lowers the phone. This
is a freshness problem, not an accuracy problem, but it defeats the product goal just as thoroughly.

### F8 — Smaller correctness gaps
- GDL90 altitude code `0xFFF` (invalid) becomes **0 ft** and passes the `> -1000` ownship guard.
- GDL90 Misc bits ignored: track-type (true track / mag heading / invalid) and airborne flag.
- adsb.lol `alt_baro: "ground"` becomes 0 ft MSL (wrong by field elevation at e.g. Denver).
- In-flight fixes worse than 500 m are discarded even when the alternative is a much older fix;
  no `verticalAccuracy` gating or altitude smoothing (that work lived only on the abandoned branch).
- Earth curvature + refraction ignored: a 50 NM target sits ~0.4° lower than the flat-earth
  elevation angle predicts.

---

## 3. Scenario matrix — what each combination needs

| Scenario | Position source | Best altitude frame | Azimuth risk | Fixes that cover it |
|---|---|---|---|---|
| Ground + internet | phone GPS | geometric (`alt_geom` ↔ phone GPS; offset-corrected `alt_baro`) | low (calibrated compass) | P2; P3.2 |
| Flight + ADS-B, unpressurized (GA, low/slow) | ADS-B ownship, DR between reports | **pressure ↔ pressure** (0x0A ↔ target baro) — immune to QNH/temp | high (cockpit iron at each anchor) | P1.1–P1.3, P2 (frame check), P3.3–P3.5 |
| Flight + ADS-B, pressurized (fast/high) | ADS-B ownship | **geometric** (0x0B ↔ `alt_geom`/offset-corrected baro); cabin baro auto-rejected | high | P1.1–P1.3, P2 (auto-detect), P3.3–P3.5 |
| Flight + internet, unpressurized | phone GPS + DR | pressure (phone absolute baro ↔ target baro) or geometric — whichever is valid | high | P1.4, P2, P3.3–P3.5 |
| Flight + internet, pressurized (airliner window seat) | phone GPS (degraded, gated) + DR | geometric (phone GPS ↔ `alt_geom`/offset) | highest (cabin iron, no calibration chance) | P1.4, P2, P3.3–P3.5 |

Azimuth risk is the same in every flight row because it comes from the cockpit environment, not the
data source — which is why the automatic corrector (P3.5) is scenario-independent by design: solar
geometry is available to a phone in a Cessna and a phone in seat 27A alike.

"Pressurized or not, unknown airplane" is handled by **auto-detection**, not a setting:
while airborne, if |cabin-pressure altitude − GPS geometric altitude| exceeds the maximum plausible
QNH+temperature band (~2,000 ft), the cabin-side baro sensors (phone *and* Sentry 0x0A) are declared
invalid for positioning and the geometric frame is used. No user input needed, no aircraft-type
assumption.

---

## 4. The plan

### P0 — Instrumentation first (the foundation everything else is judged by)
This project's history is full of plausible fixes reverted after one flight because nothing measured
*why*. Before changing behavior:
- **Flight recorder:** ring-buffered CSV log (~1 Hz + on events): phone GPS
  (lat/lon/alt/ellipsoidal/hAcc/vAcc/speed/course/courseAcc), CLHeading (mag/true/accuracy),
  ARKit camera yaw/pitch/roll + tracking state, CMAltimeter pressure & derived pressure altitude,
  ADS-B ownship (position, 0x0A, 0x0B, track, gs), every applied correction (declination, sun-anchor
  residual, altitude frame chosen, baro→geom offset), and GDL90 CRC-failure counts. Export via share sheet.
- **Per-lift session markers:** each foreground/lift starts a new log segment recording time-to-first
  usable frame, ARKit tracking state over the first 3 s, whether the session reset or relocalized,
  the anchor compass sample and its accuracy, and the alignment correction in force. Lift-and-look
  quality is only measurable per lift.
- **Info panel additions** (display only — nothing here is an input): cabin-vs-GPS altitude delta +
  pressurization verdict, altitude frame in use, baro→geom offset estimate, the three heading
  candidates (compass / GPS track / AR camera yaw), and alignment status (source + estimated
  residual).
- This turns "I think I noticed X, not sure" into data, and makes every later phase falsifiable.

### P1 — Correctness bugs (all scenarios benefit immediately)
1. **GDL90 decoding:** un-stuff `0x7D` escapes, verify CRC-16-CCITT, drop bad frames (count them for
   the log). Removes corrupted ADS-B positions on ~1 in 5 traffic reports. *(F1)*
2. **GDL90 completeness:** parse 0x0B ownship geometric altitude; treat `0xFFF` altitude and invalid
   track-type as *missing* (not 0); read the airborne flag. *(F3, F8)*
3. **Unified ownship estimator:** one source-of-truth struct (position, geometric alt, pressure alt,
   speed, track, vertical rate, timestamp, per-field validity, source). ADS-B ownship reports feed
   it with their own timestamp and velocity (dead-reckoned between 1 Hz reports); phone GPS feeds it
   only when ADS-B is absent/stale (> 2 s). Eliminates the mixed-frame extrapolation. All consumers
   (scene tick, 4 Hz loop, TCAS, map, internet-query center) read from it. *(F2)*
4. **Staleness-aware GPS gating:** accept a degraded fix (up to ~1 km) when the alternative is a fix
   older than ~10 s; gate altitude by `verticalAccuracy` and lightly smooth it. *(F8)*
5. adsb.lol `"ground"` sentinel → on-ground flag, not 0 ft. *(F8)*

### P2 — Frame-aware vertical positioning (the pressurization answer)
1. Maintain ownship altitude in **both frames** with validity: geometric (GPS MSL + HAE, ADS-B 0x0B)
   and pressure (CMAltimeter absolute pressure → ISA pressure altitude; ADS-B 0x0A).
2. **Pressurization auto-detect** as described in §3; log the verdict.
3. **Baro→geometric offset estimator:** running median of (`alt_geom` − `alt_baro`) over nearby
   internet traffic — other aircraft continuously measure the local pressure↔geometric conversion
   for us. Fallback: METAR QNH from the nearest airport (already fetched for the METAR panel); last
   resort 0.
4. **Per-target Δh selection:** pressure↔pressure when ownship pressure is valid (unpressurized) —
   the most accurate option; otherwise geometric↔geometric (`alt_geom`, or `alt_baro` + offset).
   Airports: always geometric (MSL↔MSL). TCAS uses the same Δh so alerts match what is drawn.

### P3 — Azimuth: display honesty and fully automatic alignment
The lift-and-look usage pattern reshapes this problem. Today every foreground re-runs ARKit with
`.resetTracking`, so **each lift re-anchors the AR world to a fresh cockpit compass sample** — the
dominant azimuth error is whatever the compass reads at that instant, and nothing learned earlier
in the flight survives. The fixes are all automatic:

1. **Keep** `.gravityAndHeading` + declination (the only field-validated alignment).
2. **Heading readout & 2D map** *(F5)*: in flight, display/orient by GPS or ADS-B track when moving
   (> 40 kt), else by AR camera azimuth + declination — never the raw cockpit compass. Label the
   source in the HUD.
3. **Anchor hygiene:** never (re)start ARKit while heading accuracy is poor *in flight* (extend the
   existing ground-only rules); at anchor time use a short accuracy-gated median of compass samples
   rather than whatever single value ARKit happens to grab.
4. **Session continuity across lifts:** stop issuing `.resetTracking` on every foreground. After a
   short pause, *resume* the existing session — ARKit relocalizes against the cockpit interior,
   which is a stable visual environment — and only reset when tracking is genuinely lost. Alignment
   learned earlier in the flight then survives the pocket→sky cycle: the second lift is instantly as
   good as the best moment of the flight, with zero user action.
5. **Sun-anchor auto-alignment** — the automatic corrector: solar azimuth/elevation are computable
   from GPS + time to < 0.1°, and the sun is trivially detectable in the camera frame (saturated
   blob on the downscaled luma plane, ~1–2 Hz, cheap). In daytime flight the sun is very often in
   view — above a cloud deck, almost always. Each capture **self-validates**: the detected blob is
   accepted only when its *elevation* matches the computed solar elevation (±2°) — a physical
   cross-check no compass-based correction ever had, which is exactly what the two reverted attempts
   lacked. The azimuth residual (detected − computed) then becomes the world-alignment correction:
   applied silently within ~1 s of the sun crossing the view, and stored as the flight's bias prior
   so later lifts start corrected even before the sun is seen again. Falls back to compass + prior
   when no sun is available (night, overcast on the ground). Ships as its own build with
   conservative gates and every capture logged. (Moon anchor at night is a possible follow-up.)
6. **Log-only candidate estimators** (explicitly *not* applied to placement until flights prove
   convergence, honoring the two reverts): (a) CMDeviceMotion `xTrueNorthZVertical` quaternion vs
   ARKit camera quaternion — a full-attitude comparison, immune to the vertical-device axis
   ambiguity that plausibly broke the two CLHeading-based attempts; (b) optical flow of the
   ground/cloud deck seen through the window vs GPS track — measures the aircraft's true motion
   direction in camera coordinates, fully automatic, but the hardest to validate. Either is promoted
   to an active correction only if the P0 flight logs show it converging on the sun-anchor truth.

### P4 — Instant readiness at lift *(F7)*
Accuracy the user never sees doesn't count. On foreground:
1. **Force an immediate fetch** — fix `ensureInternetFetchRunning()` so a foreground always kicks a
   fetch (invalidate the timer on background, or track last-fetch time and fire when it is older
   than the interval). The fetch should start before ARKit finishes initializing, so data and
   tracking become ready together rather than in series.
2. **Don't start from an empty sky** — on resume, show surviving targets immediately, marked stale
   (the dashed-ring treatment already exists), instead of letting the cleanup pass wipe them. Widen
   the cleanup cutoff for the resume tick only; a stale-but-labelled target is far more useful in a
   5-second glance than nothing.
3. **Keep the picture warm** — if the OS permits a brief background window, refresh once before it
   suspends; otherwise on resume prioritize the fetch over all other startup work.
4. Measure it: P0's per-lift markers record time-to-first-target and how many targets were stale at
   the first drawn frame — that's the number this phase must move.

### P5 — Long-range geometry polish
- Curvature + standard refraction in the elevation angle: subtract d²/(2·(7/6)·R) from Δh.
  ~0.4° correction at 50 NM, exact at short range, three lines of math.

### P6 — Tests & field validation protocol
- Unit tests (target exists, currently empty of logic tests): GDL90 escape/CRC vectors (from the
  spec), frame-aware Δh chooser truth table, offset estimator, dead-reckoning math, curvature term,
  solar position against published almanac values.
- Ground protocol: stand at a known point, verify overflying ADS-B traffic and 2–3 visible airports
  against the camera image; record the residual azimuth bias reported by the log.
- **Lift protocol** (the product-level test): from pocket, lift and count seconds until traffic is
  drawn and stable; repeat ~10 times per flight. This, not a single long observation, is the metric
  that matches how the app is used.
- Flight protocol (one page, in `docs/`): what to glance at in the info panel per phase of flight,
  and to export the P0 log after landing. Each phase ships as its own build so a single flight can
  attribute any regression.

### Suggested build order
| Build | Content | Risk |
|---|---|---|
| 1 | P0 + P1 (bugs are strict improvements) | low |
| 2 | P4 instant readiness + P3.2–P3.4 heading display, anchor hygiene, session continuity | low — biggest felt improvement per unit risk |
| 3 | P2 frame-aware vertical | medium — new decision logic, but fully logged |
| 4 | P3.5 sun-anchor auto-alignment | medium — self-validating and fully logged |
| 5 | P5 + P3.6 promotions *only if* log data supports them | gated on evidence |

Build 2 moved ahead of the altitude work: session continuity and instant readiness are what make a
five-second glance usable at all, and they are low-risk changes that also make every later phase
easier to evaluate in the field.

---

## 5. Explicitly out of scope (and why)
- **Manual trim / alignment gestures** — rejected by the product owner: the app must be instant and
  automatic ("the app should show the user where the traffic is, not the other way around"). All
  residual-bias correction is automatic (P3.4–P3.6); the info panel only *displays* the estimated
  residual, it never asks for input.
- Re-applying camera-bearing-vs-compass residual correction — failed two field tests (builds 113, 274).
- Restarting the ARKit session in flight to re-align — resets VIO, worse than the bias it fixes.
- `ARGeoTrackingConfiguration` — only works in mapped metro areas at street level; useless in flight.
- Fixing ARKit's internal VIO drift — closed system; we mitigate (no in-flight resets, sun-anchor
  re-correction, honest status) and measure (P0) instead.

## 6. Acceptance criteria
- **Ground + internet:** overflying airliner at ≤ 10 NM sits within ~1 ring radius of the real
  aircraft; airports on the horizon line up with their real direction.
- **Flight + ADS-B (both cabin types):** traffic called by ATC/TCAS appears within the ring at the
  correct relative altitude (above/below/level agrees with reality); no position jumps from
  corrupted frames.
- **Flight + internet:** same, with degraded-GPS tolerance; heading readout agrees with the aircraft
  DG/track within a few degrees while cruising.
- **Any scenario — the product test:** lift the phone, see correctly-placed traffic within ~2 s,
  put it down. Zero user interaction, no alignment control anywhere in the app. Specifically:
  traffic is drawn on the first or second frame (never an empty sky after a pocket period); with
  the sun anywhere in view, residual azimuth bias corrects to ≤ ~2° within about a second (verified
  against P0 logs); and across repeated lifts in one flight the alignment never regresses, because
  session continuity and the learned bias prior carry over.
