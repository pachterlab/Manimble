# manimble-examples

The upload service behind the website's [Examples page](https://pachterlab.github.io/Manimble/examples/) and
`manimbler --submit`: a Cloudflare Worker served at <https://api.manimble.com>.
Packages are stored in the private R2 bucket `manimble-examples`; their details in the D1 database
`manimble-examples`. See `src/index.ts` for the routes and limits.

## Reviewing submissions

Each submission opens an issue labelled `example` (when the `GITHUB_TOKEN` secret is set) and waits as pending.

```bash
worker/scripts/examples_admin.py list                 # pending submissions
worker/scripts/examples_admin.py download ID          # then: manimbler --check ID.manimble
worker/scripts/examples_admin.py approve ID           # it appears on the Examples page (within a minute)
worker/scripts/examples_admin.py reject ID            # deletes the package
```

The script reads the admin token from the Keychain (service `manimble-examples-admin`) or
`$MANIMBLE_EXAMPLES_ADMIN_TOKEN`. Approving or rejecting also comments on and closes the review issue.

## Developing and deploying

```bash
cd worker && npm install
echo 'ADMIN_TOKEN=devtoken' > .dev.vars
npm run migrate:local && npm run dev      # http://localhost:8787; mkdocs serve on :8000 may upload to it
npx tsc --noEmit
npm run migrate && npm run deploy         # needs `npx wrangler login`
```

Secrets (`npx wrangler secret put NAME`): `ADMIN_TOKEN`, `IP_SALT`, and optionally `GITHUB_TOKEN`, a fine-grained
token with **Issues: read and write** on pachterlab/Manimble, for the review issues.
