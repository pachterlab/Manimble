# manimble-examples

> **Archived (2026-11-19).** The Examples page switched to a gallery kept in the repository (`examples/gallery/`),
> and everything this Worker used on Cloudflare was deleted: the Worker, the `api.manimble.com` custom domain, the
> R2 bucket, the D1 database and its secrets. This branch (`archive/examples-worker`) keeps the code; to bring
> uploads back, follow [Redeploying from scratch](#redeploying-from-scratch).

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

## Redeploying from scratch

The branch is based on the commit that added the Worker, so `main` has moved on since. Bring the pieces over onto a
new branch instead of merging this one: `worker/`, `submit()` and its options in `manimbler` (with the tests in
`tests/test_manimbler.py`), the upload form in `docs/examples.md` and `docs/assets/examples.js`, the form styles in
`docs/assets/manimble.css`, `.github/ISSUE_TEMPLATE/example.yml`, and the `api.manimble.com` row in
`docs/reference/privacy.md`. `git diff fe04924^ fe04924` shows all of them.

Then, with `npx wrangler login` on the account that holds the manimble.com zone:

```bash
cd worker && npm install
npx wrangler r2 bucket create manimble-examples          # keep it private
npx wrangler d1 create manimble-examples                 # copy the new database_id into wrangler.jsonc
npm run migrate                                          # creates the tables (migrations/)
openssl rand -hex 32 | npx wrangler secret put ADMIN_TOKEN   # also store it in the Keychain:
#   security add-generic-password -U -s manimble-examples-admin -a admin -w <token>
openssl rand -hex 32 | npx wrangler secret put IP_SALT
npm run deploy                                           # also attaches the api.manimble.com custom domain
curl https://api.manimble.com/examples                   # {"examples":[]}
```

`wrangler.jsonc` still has the old `database_id`, which no longer exists, so `npm run migrate` fails until it is
replaced. Keep `workers_dev` false: the account's workers.dev subdomain carries another project's name. The rate
limit's `namespace_id` is free-form and can stay `1001`.
