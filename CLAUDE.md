# Dawnpass — Working Style

## Workflow contract

For every non-trivial change in this repo, follow this loop:

1. **Plan first.** Before writing code, propose the approach in plain text. Include what's being built, what's deliberately *not* being built, affected files, and any architectural choices worth flagging. Wait for the user to react before turning the plan into tasks.

2. **Build the to-do list.** Once the plan is agreed, break it into discrete `TaskCreate` items. Each task should be a single coherent change that can be reviewed and committed on its own. Order them so each task leaves the codebase in a working state (build + tests pass).

3. **One task at a time.** Mark the current task `in_progress` before starting, complete it, mark `completed`, then **stop**. Do not start the next task. Surface a short summary of what changed and what's next.

4. **User review + commit.** The user reads the diff, asks questions, requests adjustments, and commits when satisfied. Only after the user explicitly says to proceed (or commits and asks for the next step) does the next task begin.

5. **Repeat.**

## Why this exists

Bursts of "implement everything in one shot" are hard to review and hard to roll back. One-task-one-commit gives clean history, surgical reverts, and lets the user push back early before bad architectural choices propagate. The cost is more turns; the benefit is better code and tighter alignment.

## Exceptions

- **Trivial mechanical edits** (renames, formatting fixes, single-line typos) may be batched into one task without violating the loop.
- **Plan-mode brainstorming and naming/architecture conversations** don't trigger the loop — only execution does.
- If a task discovers it needs to split, propose the split *before* writing more code; don't silently expand scope.

## Project quick-reference

- Project name: **dawnpass** — surf forecast for the Pinellas Gulf longboard breaks.
- Subdomain: `dawnpass.brickellresearch.org` (Vercel, auto-deploys on push to `main`).
- Language: Gleam (matches Caffeine; "we're proud Gleamlins").
- Configs: JSON, not YAML (Gleam's `gleam_json` is mature; YAML support is weak).
- Architecture seam: math layer (deterministic scoring, no LLM) is strictly separate from AI layer (vision, briefs, calibration). Types enforce the boundary.
- Static site: `public/index.html` + `public/styles.css`. No inline `<style>`. CSS lives in its own file.
- Data flow (current): `gleam run` → writes `public/data/latest.json` → page fetches and renders.
- Hard rules from the project memory: no Surfline scraping; disable audio on any future cameras (FL § 934.03); design for hurricane replaceability, not survivability.
