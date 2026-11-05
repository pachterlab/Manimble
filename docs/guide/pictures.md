# Pictures and Python plots

## Insert a picture

Choose **Insert ▸ Image…** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>I</kbd>) or click **Image** in the toolbar, and choose a PNG,
JPEG, TIFF, GIF or HEIC file. Manimble copies the file into the deck folder, so the deck stays self-contained, and
adds an `ImageMobject` to the slide that refers to it by a path relative to the slide's file.

You can also paste a picture: a screenshot, a picture copied from a browser, or a picture file copied in the Finder.
See [Paste from other apps](inserting.md#paste-from-other-apps).

Select a picture to move and resize it. Its file name is shown in the inspector. To stretch a picture, turn off
**Keep aspect ratio** in the inspector and change its width or height.

## Extract elements from a picture

**Insert ▸ Extract Elements from Image…** splits a picture into its separate subjects (the people in a photo, the
parts of a figure), so each can be moved, resized and animated on its own. It uses the subject-lifting model built
into macOS, and needs macOS 14 or later.

1. Select a picture on the slide.
2. Choose **Insert ▸ Extract Elements from Image…**. A sheet shows the picture with each element the model found
   tinted.
3. Adjust the elements:
    - Click **Find Elements** to let the model find them again, or **Clear All** to start over.
    - Drag a box around something to add it as an element. The model finds the subject inside the box;
      **Whole Box** takes the box as it is.
    - Paint with the **Keep** and **Remove** brushes to fix an element's edges.
    - Select an element and click **Delete** to drop it.
4. Choose whether to **Fill in the background behind them**. With this on, Manimble paints in what was behind each
   element, so moving an element away doesn't leave a copy behind in the original picture.
5. Click **Insert**.

Each element becomes a transparent PNG in the deck folder and its own `ImageMobject`, placed exactly where it was in
the picture. One <kbd>⌘</kbd><kbd>Z</kbd> removes them all.

## Python plots

A Python plot is a picture on a slide that is drawn by running Python code, typically a
[Matplotlib](https://matplotlib.org) figure. You can run the code again at any time, so the figure stays in step with
your data.

### Insert a plot

1. Choose **Insert ▸ Python Plot…** or click **Python Plot** in the toolbar.
2. Write the plotting code on the editor's **Code** tab, or switch to **File** and click **Choose…** to link a `.py`
   file instead.
3. Click **Render** (<kbd>⌘</kbd><kbd>↩</kbd>), or click away from the editor. **Cancel** leaves everything as it
   was.

Manimble runs the code, saves the last Matplotlib figure it made as a PNG in the deck folder, and inserts it on the
slide. For other plotting libraries (Plotly, Seaborn's own saving, PIL), save the picture yourself to the path in
the `MANIMBLE_PLOT_OUT` environment variable, and Manimble uses that file.

```python
import numpy as np
import matplotlib.pyplot as plt

x = np.linspace(0, 10, 200)
plt.figure(figsize=(8, 4.5))
plt.plot(x, np.sin(x), lw=3)
plt.title("A sine wave")
```

Code written in the editor runs in the deck folder, so it can read data files there by relative path. A linked file
runs in its own folder.

### Update a plot

Hover over a plot on the slide and click **▶** to run its code again. If the output changed, the picture is replaced;
if not, nothing changes. To change the code, double-click the plot to open the editor.

Every new output is saved as its own file (`plot1@1a2b3c4d.png`), so running a plot again is an ordinary edit that
<kbd>⌘</kbd><kbd>Z</kbd> undoes. What to run is remembered beside the picture in `plot1.plot.json`.

### Which Python runs plots

The plot editor shows which Python runs the code; click **Change…** to pick another. By default Manimble uses the
first Python it finds that can import Matplotlib: its own, then your login shell's and the usual installations. If
the code imports Seaborn and that Python lacks it, Manimble offers to install it.

## BioCartoon icons

[BioCartoon](https://biocartoon.com) is a searchable library of scientific illustrations: cells, organelles,
molecules, organisms, laboratory equipment and more, gathered from open icon collections with their licences and
credits.

1. Choose **Insert ▸ BioCartoon Icons…** or click **BioCartoon** in the toolbar. The search panel opens in the
   inspector's place. If BioCartoon's command-line tool isn't installed yet, click **Install BioCartoon**.
2. Type search words. Narrow the results with the filter menus (category, collection and others); **Clear filters**
   resets them.
3. Hover over an icon to see its title, collection, licence and credit line.
4. Click an icon to insert it in the middle of the slide, or drag it onto the slide to place it.

Right-click an icon to copy its name or its credit line, which most licences ask you to show. Icons are kept on your
Mac after their first use, so they work offline. Click the **×** in the panel's corner to return to the inspector.
