# Tally Oh

iOS app (Swift, UIKit + SceneKit/ARKit) that draws nearby air traffic and airports in AR.
Gev (@simongev) is founder and CEO, and has the final say on everything here.

## Non-negotiable rules

1. **Only Gev merges to `main`.** Branch off it freely; never commit to it, merge into it, or
   push to it. Hand over a branch and a verdict. There are no pull requests in this repo — Gev
   merges locally after flying the build.
2. **Never force-push. Never rewrite published history. Never delete a branch you did not
   create.** Every branch, not just `main`.
3. **One feature, one team, one branch**, named `feature/<short-name>`, `fix/<short-name>` or
   `chore/<short-name>`.
4. **Use git worktrees** when more than one agent is working in a single session — subagents
   share a filesystem and will otherwise overwrite each other.
5. **No secrets in source, ever.** Keys go in a gitignored config (`Secrets.xcconfig`). If a key
   does not exist yet, stop and ask Gev. Never invent a placeholder and commit it.
6. **Nothing goes to App Store Connect without Gev's explicit yes for that specific build.** Not
   a standing approval, not inferred from an earlier one. Ask every time, even when he asked for
   the same thing yesterday.

## How work flows

```
issue (spec + acceptance criteria)
  -> feature/<name>, own branch, own worktree
  -> dev agent commits and pushes
  -> CI builds and tests on every push
  -> QA agent: PASS, or REJECT with file:line and what the bar is (max 3 rounds)
  -> CTO reviews architecture and fit
  -> Gev says ship -> deploy dispatched from that branch -> Gev flies it
  -> works -> Gev merges to main
```

Handoff state lives in the feature's GitHub issue, not in agent memory. Sessions are ephemeral;
the issue thread is what survives. QA never writes production code.

## ARKit does not run in the Simulator

No camera, no world tracking, no device motion. Node placement, visibility at distance, tracking
stability, frame rate and thermal behaviour can only be verified by Gev holding the phone.
**Every handoff must end with an explicit list of what could not be verified.** Never imply the
AR side is tested.

## Hard-won lessons — corrected, current as of build 41

Several of these were learned in an older version of the code and are no longer true. Re-applying
them verbatim would break the app. Verify before acting on any of them.

- **Distance is compressed onto a 5–80 m shell**, not a ~500 m one
  (`ARComponentFactory.minARRadius`/`maxARRadius`). Everything goes through
  `ARComponentFactory.scaledPosition`. Only angular error matters; see `docs/AR_ACCURACY_PLAN.md`.
- **Do NOT set `isUserInteractionEnabled = false` on the AR view.** The old rule was true once
  and has been deliberately reversed: tap-to-select is a gesture recognizer on `arSceneView`.
  Button touches are handled by adding buttons as siblings above it, and pinch/pan live on
  `self.view` so ARKit cannot swallow them.
- **Node sizes are much larger than intuition suggests** — scene units are metres on an 80 m
  shell, so rings are 3.6–5.5 m and the airport cone is 9.6 m. Do not "correct" these down.
- **Emoji in status labels is fine now.** The old ban was about `SCNText`, which no longer
  exists anywhere; labels are cached `UIImage`-textured `SCNPlane`s and the HUD is a `UILabel`.
- **Start internet updates immediately.** Fetching begins during calibration, before the AR view
  exists. Do not gate it behind the ADS-B timeout — that is what made the app feel dead.
- **Memory pressure is handled; do not re-fix it.** `SCNText` is gone, label images are cached
  (`NSCache`, 200 entries / 40 MB) and updates are content-gated. All timers use `[weak self]`
  and are invalidated. `ConnectionLogic` holds no back-reference to the view controller — it
  publishes via Combine and every subscriber captures weakly. Keep it that way.

## Codebase tripwires

These merge cleanly and *then* break the build or the app.

- **No module-scope free functions.** `angleDifferenceDeg` and `worldIsUsableForDisplay` are the
  existing ones. Two branches each adding a `wrap180` at file scope compile fine alone and fail
  after the merge with a redeclaration error and no textual conflict. Put helpers inside a type.
- **One new setting touches four files** — `ARVisualizationSettings` in `MainAppComponents.swift`,
  its `UserDefaults` extension and its row table in `SettingsViewController.swift`, and the view
  controller. Settings additions are serialized through one team; check with the CTO first.
- **Any `.swift` under `Tally-Ho/` is compiled.** The project uses file-system synchronized
  groups, so there is no such thing as a file that is present but not built. No scratch files,
  no `.swift.bak`, no half-finished experiments in the tree. (The upside: adding a file never
  conflicts in `project.pbxproj`.)
- **Never hand-edit `CURRENT_PROJECT_VERSION` or `MARKETING_VERSION`.** Each appears in six
  places in `project.pbxproj`. CI sets the build number from the workflow run number.
- **`struct Aircraft` (`ConnectionLogic.swift`) is the universal DTO** — a new field ripples into
  nine files. Coordinate through the CTO.

## Build and test

CI runs `xcodebuild test -scheme "Tally-Ho"` on a simulator for every push to every branch.
Run the same thing locally before pushing if you have Xcode. Cloud agent containers have no
Swift toolchain at all, so CI is the only compiler available to them — read its logs rather than
guessing whether something builds.
