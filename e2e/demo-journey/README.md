# OpenBoxes demo browser journey

This Playwright journey creates a demo product, records 25 units at Main Warehouse, and verifies the quantity on hand from the product search UI. It uses the same specs for local and remote OpenBoxes environments; only `BASE_URL` needs to change. Run it only against a disposable/test environment because the journey creates application data.

## Prerequisites and installation

- Node.js 18 or newer and npm
- Chromium's operating-system dependencies (see [Playwright's browser setup](https://playwright.dev/docs/browsers))

From this directory:

```sh
npm ci
npx playwright install chromium
```

The harness pins `@playwright/test` to `1.63.0` and uses TypeScript specs.

## Run locally

The defaults are `BASE_URL=http://localhost:8080/openboxes`, `OB_USER=admin`, and `OB_PASSWORD=password`.

```sh
npm test
```

The runner uses one worker and executes `journey.spec.ts` before `verify.spec.ts`. To run just the persistence check:

```sh
npm run test:verify
```

`RUN_ID` optionally controls the synthetic product and lot suffix; by default it is a timestamp. The journey writes `test-results/journey-state.json`, which the verify spec reads unless `PRODUCT_CODE` is supplied:

```sh
PRODUCT_CODE=YOUR-PRODUCT-CODE npm run test:verify
```

After restarting the application while leaving its database intact, run the same persistence check:

```sh
npm run test:verify
```

## Run against another environment

Use the same install and test commands, changing only the base URL:

```sh
BASE_URL=https://openboxes.example.org/openboxes npm test
```

Optional `OB_USER`, `OB_PASSWORD`, and `RUN_ID` variables can be set when the target environment needs different credentials or a fixed run identifier.

## Outputs

Named step screenshots, videos, traces, the HTML report, and `journey-state.json` are written under `test-results/`. Each Playwright invocation gets a timestamped artifact/report subdirectory; set `PW_RUN_LABEL` to choose a readable label. The directory is gitignored, and the state file is deliberately outside Playwright's per-run output directory so a separate verify invocation can reuse it.
