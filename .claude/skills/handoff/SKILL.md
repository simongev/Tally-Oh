---
name: handoff
description: Produce the CTO handoff for a finished branch - the verdict Gev reads before deciding whether to ship a build, plus his manual test card. Use after QA has returned PASS and the architecture review is done.
---

# Handoff

This is the last thing that happens before Gev decides anything. He reads it, then says ship or
doesn't. Write it for someone who has not seen the diff and will be holding a phone in a cockpit.

Short. No preamble, no restating the brief.

## Template

```
## <feature name>  —  branch `feature/<name>`

**Recommend / Don't recommend** shipping this build.

**What it does**
Two or three sentences, in terms of what changes on the screen or in the numbers.

**What changed**
- path/to/File.swift — what and why
- (files only; no line-by-line)

**Verified**
- CI green on <sha> — N tests
- <anything QA could actually check>

**COULD NOT VERIFY — check on the phone**
- [ ] ...
- [ ] ...

**Risk**
The one thing most likely to be wrong, and what it would look like if it is.
```

## Rules for the "could not verify" list

It is never empty on a change that touches AR. ARKit gives nothing in the Simulator: no camera,
no world tracking, no device motion. Anything in this list that the reader could mistake for
tested must be spelled out.

Default entries when the diff touches the AR path at all:

- Node placement against the real aircraft or airport
- Visibility at distance (the 5–80 m shell means a target at 30 NM is drawn at 80 m)
- Tracking stability and drift over a session
- Frame rate and thermal behaviour
- Anything under `ARSCNViewDelegate` or the heading/yaw correction path

Write each as something Gev can actually do — "hold up at a known airport and check the marker
sits on the runway", not "verify placement accuracy".

## Risk section

One item. The most likely failure, stated as a symptom he would notice in flight, not as a code
concern. If the honest answer is "this could make every target sit 10° left and look fine on the
ground", say that.

## After the handoff

Gev decides. If he says ship, **ask before dispatching the deploy — every time, for that
specific build.** An approval yesterday is not an approval today, and an approval of a plan is
not an approval of an upload.
