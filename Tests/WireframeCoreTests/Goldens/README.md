# Golden files

Committed reference drawings for (fixture × view) combinations.

- `<name>.json` — Codable `LineDrawing`, full precision. This is what tests
  compare against, numerically (1e-9 absolute per coordinate, after canonical
  ordering) — never string equality.
- `<name>.svg` — human-diffable companion artifact, regenerated alongside the
  JSON but not compared by tests. Open in a browser to eyeball changes.

Regenerate all goldens:

```sh
RECORD_GOLDENS=1 swift test
```

The recording run deliberately fails ("golden … recorded") so a recording
configuration can never silently pass CI. Rerun `swift test` afterwards to
verify against what was just recorded, and review the git diff before
committing regenerated files.
