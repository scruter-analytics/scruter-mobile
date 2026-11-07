# Scruter mobile protocol — conformance kit

The wire protocol v1 of the Scruter SDKs (iOS, Android, React Native, Flutter): `docs/MOBILE.md` in the Scruter
monorepo is the normative behaviour, `docs/API.md` §5.3 the HTTP shapes. This directory holds what every SDK and the
backend test against:

- `schema/*.schema.json` — JSON Schema (2020-12) of every body: `batch` (`POST /m/v1/batch`), `config` (the answer of
  `GET /m/v1/config`), `team-register`, `team-screen` (`meta` and `tree` of `POST /m/v1/team/screens`), `symbols`.
  The schemas are strict (what a conforming SDK sends); the server is lenient (it clamps and drops items).
- `fixtures/` — golden fixtures, one JSON file each: `steps` of `{request, expect}` (status, exact body, a subset of
  it, or an error code) and, for the backend tests, `stored` (what ClickHouse must hold afterwards). `batch/valid`,
  `batch/dropped` (answered `202` but not stored, or partly), `batch/invalid` (rejected), `config`, `skan` (Apple's own
  signed SKAdNetwork examples, app-id 525463029).
- `validate.mjs` — a dependency-free validator: `node validate.mjs batch payload.json`.
- `run.mjs` — posts every fixture to a running ingest and checks the answers:

```sh
node run.mjs --schemas-only                       # bodies against the schemas, no server
node run.mjs --ingest http://127.0.0.1:4100 --app ATMONA02
node run.mjs --ingest http://127.0.0.1:4100 --app ATMONA02 --only batch/valid
```

The app given to `--app` must be an app property with the conformance identifiers: iOS bundle id and Android package
`fr.scruter.conformance`, App Store id `525463029`, time zone `Europe/Paris`, ignored versions `0.9.*`, in a workspace
whose trial is running (full collection). The backend's tests create it themselves (`scruter-ingest`, test
`mobile_e2e::conformance_fixtures`, which also checks the stored rows). Placeholders replaced per fixture: `{{APP}}`, `{{BATCH}}`, `{{BATCH2}}`, `{{SESSION}}`,
`{{DAILY}}` (random ids), `{{TODAY}}` (date in Europe/Paris), `{{NOW}}`, `{{NOW-<ms>}}`, `{{NOW+<ms>}}` (numbers, ms).

SDK test suites use the schemas to check the batches they build (record the request body, then
`node validate.mjs batch <file>`), and the fixtures' bodies as examples of every item kind. A protocol change edits
the schema, the fixtures, `docs/API.md` §5.3 and the server in the same commit.
