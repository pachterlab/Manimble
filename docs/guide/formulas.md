# Formulas

Formulas are Manim `MathTex` objects: LaTeX, typeset by the TeX installation on your Mac, so they look exactly as
they do in a paper.

## Insert a formula

1. Choose **Insert ▸ Formula…** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>E</kbd>), or click **Formula** in the toolbar.
2. Type the formula in LaTeX math notation, without dollar signs. For example:

    ```latex
    \int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}
    ```

3. The preview under the editor is compiled by your real TeX as you type, so errors show before you apply.
4. Click **Apply** (<kbd>⌘</kbd><kbd>↩</kbd>).

The formula is added to the build on screen. Drag it into place and resize it like any object.

## Edit a formula

Double-click the formula, or select it and click **Edit LaTeX…** in the inspector. The same editor opens with the
formula's LaTeX. Edit it and click **Apply**.

If the formula comes from a constant used on several slides, such as `FORMULA = r"e^{i\pi} + 1 = 0"` in a shared
file, the editor shows **Change everywhere (FORMULA in config.py, used 2×)**. Leave it ticked to change the
definition, or untick it to change this slide only.

!!! warning "Formulas that code refers to by their parts"
    Code can pick parts of a formula by their LaTeX, for example with `get_part_by_tex`, to colour or animate them.
    Changing the formula can break that code. If it does, the slide shows an error; fix the LaTeX or the code that
    selects the part.

## Colour and size

Select a formula to set its colour in the inspector, or resize it by dragging a corner. Bold and italic apply to
plain text only; in a formula, use LaTeX commands such as `\mathbf{}`.

## Superscripts and subscripts

Use LaTeX: `x^{2}` and `a_{n}`. The Format menu's Superscript and Subscript commands are for plain text.

## Missing LaTeX packages

A formula that uses a package your TeX installation lacks fails to render, and the error names the missing file.
Install the package with `tlmgr install <package>` in the terminal (with `sudo` for a system-wide TeX such as
MacTeX), then edit the formula again. See [Troubleshooting](../reference/faq.md#a-formula-wont-render).

Formulas are compiled once and cached, so an unchanged formula costs nothing on later renders. A new formula takes
about half a second the first time.
