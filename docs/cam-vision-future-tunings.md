# Cam Vision — Future Tunings & Detailed Learnings

Captured on **2026-05-03** during the initial exploration of feeding a live webcam at Pass-a-Grille into Dawnpass as an internal AI signal. This document is a parking lot, not a build plan: it preserves the technical recon, the architecture sketch, and the calls we made (or deferred) so that when we come back to actually wire this up the context isn't lost.

The cam-vision pipeline is **internal to the recommendation engine**. Its output does not appear in `latest.json` and is not rendered by the static site. It exists to give a future AI layer a ground-truth observation to compare against the deterministic math.

---

## 1. The Don Cesar live cam — endpoint reconnaissance

Source page: https://www.doncesar.com/live-feed/

### What it actually is

Not HLS, not YouTube, not WebRTC, not MJPEG. The page injects a Prismcam / Luma player (`js.prismcam.com/luma.js`) which surfaces **periodic JPEG snapshots** stored in a public Google Cloud Storage bucket. Frames upload roughly every 4–5 minutes (verified two consecutive paths 4 min apart on 2026-05-03).

### The two endpoints

**Discovery (JSONP):**

```
https://php.prismcam.com/public/helpers/cam_init.php
  ?cams=1551290155
  &pages=1551290155
  &url=https%3A%2F%2Fwww.doncesar.com%2Flive-feed%2F
  &callback=cb
```

Non-obvious gotcha: **must pass both `cams=` and `pages=`**. Pass only one and the response is a stub. The JSON returns `current.imagePath` like `00080/2026/05/03/14-48`.

**Snapshot (public GCS, no auth, no Referer/Origin checks):**

```
https://storage.googleapis.com/prism-cam-00080/{imagePath}/{size}.jpg
```

Available sizes: `180`, `360`, `720`, `1080`. The `1080` variant is `1920x1080` JPEG baseline, ~340 KB. `cache-control: public, max-age=86400`. CORS is open. HTTP/2 with HTTP/3 advertised.

The bucket name is `prism-cam-00080` — that's the internal page id (80) zero-padded to five — **not** the public cam ID `1551290155`. If we ever switch cams, this naming scheme is the trip-wire.

### What's in frame

- Coordinates returned by the API: `27.708849, -82.739365` (Don Cesar rooftop, ~1.5 mi north of Pass-a-Grille pier).
- View: SW-facing rooftop angle from the Don's pink Mediterranean tower, looking south down the beach toward Pass-a-Grille.
- Composition: pool deck and lounger rows in foreground, full sand strip mid-frame, **Gulf surf zone visible** through the mid- and far-distance.
- Boats on the right edge.
- Daylight: snapshots track local daylight; nighttime frames are dark and not useful.

This is a real surf-relevant view, not a pool cam.

### Auth, restrictions, polite-citizen notes

- No auth on the snapshot URL.
- No Referer or Origin enforcement — `curl` with no headers gets 200.
- The discovery endpoint does some allowedDomain filtering server-side, but returns the imagePath when both `cams` and `pages` are present.
- Page `robots.txt` only disallows `/wp/wp-admin/`.
- Polite-citizen recommendations: identify with a descriptive User-Agent that includes a contact email, don't poll faster than the 5-min upload cadence (it doesn't help anyway), don't republish frames.

### Geometric comparison vs WebCOOS Madeira CoastCam

| | Don Cesar | WebCOOS Madeira |
|---|---|---|
| Distance from Pass-a-Grille | ~1.5 mi | ~3 mi north |
| Orientation | South, **toward** Pass-a-Grille | NE alongshore (Cam 1) / east offshore (Cam 2) — both **away** from Pass-a-Grille |
| Resolution | 1920x1080 | (verify via WebCOOS API) |
| Cadence | ~5 min | hourly historically (2017–2022 in archive — verify current) |
| Source type | Hotel marketing cam (could vanish) | USGS scientific, calibrated, stable |

**Decision year one:** Don Cesar is geometrically the best free Pass-a-Grille-facing cam. Use Don Cesar primary. WebCOOS Madeira is the institutional fallback for outage windows. Don't invest in the WebCOOS leg until we hit a real outage.

### Minimum-viable fetch logic

1. GET the cam_init JSONP. Strip `cb(` prefix and `)` suffix. Parse JSON, read `pages[0].current.imagePath`.
2. Compare imagePath to the most recent value in `data/cam_log.jsonl`. If unchanged, skip — same frame, no new information.
3. GET `https://storage.googleapis.com/prism-cam-00080/{imagePath}/1080.jpg`.
4. Pass bytes to vision step.
5. On any HTTP error, log and skip; the next tick will retry.

### Outage handling

- Marketing cam, could go offline without notice (TripAdvisor threads show historical outages).
- If `cam_init` fails or `imagePath` is older than ~30 minutes (i.e. stale / paused upload), fall back to WebCOOS Madeira (year-two work).
- For now: log the outage in the JSONL with a sentinel record so the recommender can detect "we have no cam signal."

---

## 2. Architecture seam — math vs AI vs cam

The repo's `CLAUDE.md` already declares the math/AI seam: deterministic math is strictly separate from AI, types enforce the boundary. The cam-vision pipeline is **the first occupant of the AI side of that seam**.

### Layered model

```
Numerical sources           AI signals             Math layer            Recommender
(public, in latest.json)    (internal)             (deterministic)       (combines + decides)
─────────────────────────   ──────────────────     ─────────────────     ─────────────────
NDBC 42036                  Don Cesar cam          fuse(buoy,tide,         math.score
NOAA tide 8726520            → CamAssessment       wind) → score +       + cam observation
Open-Meteo marine                                  reason codes          + confidence
                                                                         ↓
                                                                         FinalRecommendation
                                                                         (+ disagreement flag)
```

### The disagreement flag is the load-bearing year-one output

The single most valuable signal coming out of this whole apparatus is the moment when **the math says "firing" and the cam says "flat,"** or vice versa. Those events are the calibration dataset.

Suggested logic (lives in the future fusion module, not in cam-vision):

```gleam
// pseudo-shape, not real Gleam yet
disagreement = abs(math_score_norm - cam_score_norm)   // 0..1
flag = disagreement > 0.35 && cam.confidence > 0.6
```

When flagged, log the math inputs, the cam assessment, and the timestamp. Eyeball weekly. After ~4 weeks of data, the patterns of disagreement become the training set for tuning math weights — without ever letting the LLM author the recommendation.

### Confidence weighting (proposed, not committed)

```
final = cam.confidence < 0.5
        ? math.score                                   // ignore cam
        : 0.7 * math.score + 0.3 * cam.score           // blend
```

The math always anchors. The cam never overrules — it nudges and flags.

---

## 3. CamAssessment — proposed record shape

```gleam
pub type WaveActivity {
  Flat
  Ripples
  Small
  Fun
  Solid
  Blown
}

pub type WindSurface {
  Glassy
  LightTexture
  Choppy
  Whitecaps
  UnknownSurface
}

pub type WindDir {
  Offshore
  Cross
  Onshore
  UnknownDir
}

pub type Visibility {
  Clear
  Hazy
  Rain
  Dark
  Obstructed
}

pub type CamAssessment {
  CamAssessment(
    captured_at: String,            // ISO-8601
    image_path: String,             // dedupe key
    wave_activity: WaveActivity,
    est_face_height_ft: Option(Float),
    wind_surface: WindSurface,
    wind_direction_visual: Option(WindDir),
    crowd_count: Option(Int),
    visibility: Visibility,
    confidence: Float,
    notes: String,                  // <= 200 chars
    model_id: String,               // e.g. "claude-sonnet-4-6"
    prompt_version: String,         // bump on prompt change
  )
}
```

Important fields and why:

- `image_path` is the dedupe key — same path, same frame, no need to re-spend tokens.
- `confidence` is the load-bearing field for fusion; without it the LLM output can't be weighted.
- `model_id` and `prompt_version` are A/B comparability metadata. Without them, retrospective comparisons across model swaps and prompt iterations are guesswork.
- `notes` is bounded short to keep the JSONL tractable and discourage the model from writing essays instead of structured fields.

---

## 4. Vision call — implementation notes

### Why direct Anthropic API, not Vercel AI Gateway

- One fewer account dependency.
- One fewer moving part to debug when something goes wrong at 5am before a session.
- No streaming, no tool use, no structured-output enforcement engine — we're making a single one-shot HTTPS POST. The Gateway's main pitches (fallback providers, unified billing, observability) don't earn their weight here.
- Revisit if/when we want provider failover or want the full AI SDK observability story.

### Endpoint shape

`POST https://api.anthropic.com/v1/messages`

Headers:

```
x-api-key: $ANTHROPIC_API_KEY
anthropic-version: 2023-06-01
content-type: application/json
```

Body sketch (the actual implementation lives in `cam/vision.gleam` when we build it):

```jsonc
{
  "model": "claude-sonnet-4-6",
  "max_tokens": 512,
  "system": "You are a surf-cam observer. Output ONLY a single JSON object matching the schema. No prose.",
  "messages": [
    {
      "role": "user",
      "content": [
        { "type": "image", "source": { "type": "base64", "media_type": "image/jpeg", "data": "..." } },
        { "type": "text", "text": "<schema + asks here>" }
      ]
    }
  ]
}
```

### Gleam-specific friction (anticipate)

- No native AI SDK, no zod. We're hand-rolling the JSON encode and decode. `gleam_json` decoders are explicit; expect ~30–40 lines of decoder per record.
- No structured-output enforcement. Mitigation: a tight system prompt that says "JSON only, no prose," followed by a parse step that **logs and skips** on failure rather than retrying. The next tick is 15 minutes away — retries don't pay.
- No streaming. Fine — we don't need it.
- Base64 encoding the JPEG: the Erlang stdlib has `base64:encode/1`; from Gleam, use a small FFI shim or whatever the current `gleam_stdlib` exposes (verify at build time).

### Prompt shape (rough)

System: tight, schema-only, refuse-prose-mode.

User text alongside the image: include the lat/long, the local time, and ideally the latest buoy + tide reading so the model has physical context for what it's looking at. **Critical:** instruct the model that the buoy/tide values are context for it to *cross-check*, not values it should parrot back. Without that the model will just echo the buoy reading into `est_face_height_ft`.

The prompt is going to need 3–5 iterations before it produces useful output. Plan for that — version it (`prompt_version` field on every record) so we can see when output quality changes.

---

## 5. Storage — JSONL on disk

Path: `data/cam_log.jsonl` (gitignored).

Schema: one `CamAssessment` per line, encoded by `gleam_json`.

Why JSONL over a DB:
- Replay-friendly. The recommender just reads the tail.
- Consistent with the project's static-JSON ethos.
- Append-only — no migrations to manage.
- Trivial to copy off-machine when we eventually port to a real backend.

When we'd outgrow it: when the recommender wants efficient time-range queries, or when we want concurrent writers (we won't, year one). At that point, port to Postgres (Neon via Vercel Marketplace) and treat the JSONL as the seed file.

Optional companion: `data/cam_frames/{YYYY-MM-DD}/{HH-MM}.jpg` for a thumbnail archive if we ever want to re-score historical frames against a new prompt. **Skip year one** — the structured assessment plus `image_path` (which can fetch the frame from GCS as long as the cam stays online) is enough.

---

## 6. Trigger model — launchd, year one

Vercel Cron is **out**. Vercel Functions don't support Erlang/BEAM.

Realistic options surveyed:

1. **macOS launchd on the user's MacBook.** Pick. `*/15 11-23 * * *` (UTC, ≈ 7am–7pm ET) runs `gleam run -m dawnpass/cam/tick`. Zero hosting cost. Fits "local-only year-one." Caveat: only ticks while the laptop is on and awake.
2. **GitHub Actions cron.** Always-on, free for personal repos. Cost: introduces CI as a runtime dependency for a logical pipeline that is otherwise local; adds a layer to debug when ticks fail. Move here when reliability matters.
3. **Tiny always-on worker on Fly.io / Render free tier.** Overkill year one.

Migration path: when the recommender wants reliable history regardless of laptop state, port the launchd plist to a GH Actions workflow. The Gleam code doesn't change — it's the same `gleam run -m dawnpass/cam/tick` invocation. The JSONL becomes a workflow artifact or gets pushed to a Blob bucket.

---

## 7. Daylight gating

The cam is useless in the dark. Two levels:

- **Coarse:** hardcode a UTC window in the trigger schedule (e.g. `11-23` UTC ≈ 7am–7pm ET). Cheap, slightly wrong at solstices.
- **Fine:** compute civil dawn/dusk for `27.708849, -82.739365` and gate inside `cam/tick.gleam`. Cleaner but requires a sun-position calculation.

Year one: **coarse**. The model already returns `Visibility::Dark` if a frame slips through during low light, and that record is itself useful (we know we tried).

---

## 8. Model selection notes

- **Default: `claude-sonnet-4-6`.** Vision-capable, current generation, good cost/quality.
- **Cheaper option to A/B: `claude-haiku-4-5-20251001`.** Run the same frame through both, log both records (different `model_id`), eyeball the agreement. If Haiku tracks Sonnet on the easy frames, demote Sonnet to a "tiebreaker" call only on low-confidence Haiku output.
- **Don't yet:** Opus. Vision quality gain probably doesn't justify the cost on a hotel webcam.

The `model_id` field on every record is what makes the A/B free — you don't need a separate experiment harness.

---

## 9. Things we deliberately deferred

- **Fusion / reconciliation logic** with the math layer (separate ticket; the math layer also doesn't fully exist yet).
- **Any UI surface** for the cam result. Internal signal only.
- **WebCOOS Madeira fallback wiring.** Build only after a real outage proves we need it.
- **Frame thumbnail archive.** Skip until we want to re-score historical frames.
- **AI Gateway / multi-provider routing.** Direct Anthropic year one.
- **Database storage.** JSONL on disk year one.
- **Cron in CI.** launchd year one.
- **Prompt version 2+.** v1 ships; we iterate from real-world output.

---

## 10. Open questions to revisit when we pick this back up

- Confirm `gleam_httpc` handles the body sizes we'll be sending (a 1080p JPEG base64-encoded is ~450 KB).
- Confirm the Gleam base64 path — is there a stdlib function or do we need an Erlang FFI shim?
- Decide between hand-written JSON decoders and a more macro-driven approach if `gleam_json` adds one before we get to it.
- Decide whether `model_id` and `prompt_version` should be stored on every JSONL row (current proposal) or in a separate side-file with a foreign key (lower duplication, more complexity).
- Decide whether to capture the buoy/tide context on every cam record (so each row is self-contained for retrospection) or to join on timestamp at recommender time (skinnier records, harder to retrospect after old buoy data is purged). I lean self-contained.
- Daylight: hardcode UTC window or compute civil dawn/dusk?
- Outage detection threshold: what's "stale" — 15 min, 30 min, an hour without a new `imagePath`?
- Where does the launchd plist live in the repo? (`ops/launchd/dawnpass-cam.plist`?)

---

## 11. References to the conversation that produced this

- The Prismcam endpoint reconnaissance was done live by a recon subagent on 2026-05-03; it pulled an actual frame and verified resolution/cadence/auth behavior.
- The architecture sketch went through one `vercel:ai-architect` agent pass that assumed Next.js / TypeScript / AI SDK. That recommendation was then translated to the actual Gleam stack in this repo. Key translations: AI Gateway → direct Anthropic, zod → hand-rolled `gleam_json` decoders, `generateText` → raw HTTPS POST, Vercel Cron → launchd.
- The earlier-than-final placement question ("inside `latest.json` or a separate file") was resolved differently from both options: the cam output is **internal**, so it doesn't go in `latest.json` at all. It lives in `data/cam_log.jsonl` and is read by the (future) recommender, never by the static page.
