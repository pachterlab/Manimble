---
title: Examples
hide:
  - toc
---

# Examples

Presentations made with Manimble, shared by the people who made them. Download one to see how its slides are built,
present it, or reuse its ideas in your own deck. To open one, choose **File ▸ Open Deck or Project…** in Manimble and
pick the downloaded `.manimble` file.

<div class="mb-buttons" markdown>
[Submit an Example](#submit-an-example){ .md-button .md-button--primary .mb-submit-toggle }
</div>

<!-- Filled in by docs/assets/examples.js from the examples service (worker/), which lists approved examples. -->
<div class="mb-examples" data-service="https://api.manimble.com">
<p class="mb-examples-empty">No examples yet. Be the first to share one!</p>
</div>

## Submit an example

Share a presentation you made with Manimble, so that others can learn from it. Package it with
**File ▸ Package for Sharing…**, then fill in the form below. Each example is reviewed before it appears on this
page.

<form class="mb-submit-form" autocomplete="on">
  <label><span>Presentation file <span class="mb-required">*</span></span>
    <input type="file" name="file" accept=".manimble" required>
  </label>
  <label><span>Title <span class="mb-required">*</span></span>
    <input type="text" name="title" maxlength="200" required>
  </label>
  <label><span>Authors <span class="mb-required">*</span></span>
    <input type="text" name="authors" maxlength="500" placeholder="Ada Lovelace, Charles Babbage" required>
  </label>
  <label>Institution
    <input type="text" name="institution" maxlength="200" placeholder="University, company or lab">
  </label>
  <label>Date
    <input type="date" name="date">
  </label>
  <label>Keywords
    <input type="text" name="keywords" maxlength="300" placeholder="topology, lecture, animation">
  </label>
  <label class="mb-wide">Description
    <textarea name="description" rows="3" maxlength="2000" placeholder="A sentence or two about the talk"></textarea>
  </label>
  <label class="mb-wide mb-check">
    <input type="checkbox" name="agree" required>
    <span>I have the right to share this presentation, and agree that it may be shown on this page and downloaded by
    anyone.</span>
  </label>
  <div class="mb-wide mb-submit-actions">
    <button type="submit" class="md-button md-button--primary">Submit</button>
    <progress max="1" value="0" hidden></progress>
  </div>
  <p class="mb-wide mb-submit-status" role="status" aria-live="polite"></p>
</form>

Packages can be up to 95 MB. For a larger one, upload it to a service such as Zenodo, Google Drive or Dropbox and
[open an issue on GitHub](https://github.com/pachterlab/Manimble/issues/new?template=example.yml) with its link.

### From the command line

[`manimbler`](sharing/projects.md#the-manimbler-command-line-tool) can check a package and submit it:

```bash
manimbler --submit talk.manimble --title "Knots in 3D" --authors "Ada Lovelace, Charles Babbage" \
    --institution "Analytical Engine Lab" --date 2026-11-19 --keywords "topology, lecture"
```

It verifies the package first, asks for a title and authors if you didn't give them, and asks you to confirm that you
may share it (or pass `--yes`) before uploading.
