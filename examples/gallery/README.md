# Examples gallery

The presentations listed on the website's [Examples page](https://pachterlab.github.io/Manimble/examples/).
The page reads `examples.json` from the `main` branch each time it loads, so an example appears as soon as it is
merged to `main`; the site does not need to be rebuilt.

## Adding an example

1. In Manimble, choose **File ▸ Package for Sharing…** and save the `.manimble` package in this folder. Give it a
   short, lowercase name with dashes, such as `knots-in-3d.manimble`. GitHub refuses files over 100 MB.
2. Add an entry to `examples.json`. Newest first is a good order; the page keeps the order of the file.

```json
[
  {
    "file": "knots-in-3d.manimble",
    "title": "Knots in 3D",
    "authors": "Ada Lovelace, Charles Babbage",
    "institution": "Analytical Engine Lab",
    "date": "2026-11-19",
    "keywords": ["topology", "lecture"],
    "description": "A sentence or two about the talk."
  }
]
```

`file`, `title` and `authors` are required; the rest are optional. `date` is `YYYY-MM-DD`.

3. Run `python3 -m unittest tests.test_examples_gallery`, which checks every entry and runs `manimbler --check` on
   every package, then commit and merge to `main`.

## Taking submissions instead

An earlier design let anyone upload an example, through a Cloudflare Worker at `api.manimble.com` with a review
step. It was taken down before launch; its code and the steps to redeploy it are on the
[`archive/examples-worker`](https://github.com/pachterlab/Manimble/tree/archive/examples-worker/worker) branch.
