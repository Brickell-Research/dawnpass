# dawnpass

> Reading the Gulf, one window at a time.

Surf forecast for the Pinellas Gulf longboard breaks. A [Brickell Research](https://brickellresearch.org) project.

The name does triple duty: dawn at the Pass (Pass-a-Grille is *the Pass* to locals), a dawn pass / admission ticket, and passing the watch at dawn.

## Status

v0 — pre-release. Currently emits "the watch is up" and not much else. Forecast logic, scoring, and rendering land next.

## Local development

```sh
gleam run     # run main
gleam test    # run tests
gleam format  # format src/ and test/
```

Requires Gleam ≥ 1.16 and Erlang/OTP ≥ 27.

## How it ships

`forecast.yml` runs hourly in GitHub Actions: pulls NDBC buoy 42036, NOAA tide 8726520, and Open-Meteo, computes a score and window, renders `public/index.html`, and commits `data/` + `public/` back to `main`. Vercel auto-deploys to `dawnpass.brickellresearch.org`.

`ci.yml` runs format/build/test on PRs and on pushes that change source.
