# Scripted presentations

A scripted presentation plays the deck by itself. On each build it speaks the words you wrote for it, moves an
on-screen pointer to what you are talking about, and then goes on to the next build. Use it for a recorded talk, a
kiosk display, or to rehearse timing.

The script is kept in `script.json` beside the deck's code, not in the Python, so writing a script never re-renders a
slide.

## Write a script

1. Go to the build the words belong to.
2. Click **Script** on the Home bar. The Script panel opens in the inspector's place, listing the steps of the build
   on screen.
3. Add steps with the Add buttons:
    - **Speak:** words to say. Type them into the step. <kbd>↩</kbd> starts a new line.
    - **Mouse:** a pointer movement. Click **Set on Slide**, then click the point the pointer should go to, or drag
      to trace the path it should follow. **Speed** sets how fast it moves, and **Wobble** adds a slight, natural
      unsteadiness.
    - **Pause:** a wait, in seconds.
4. Reorder steps with their arrows, and remove a step with its delete button.

Steps run in order when the show reaches that build. Click a step to play it on the slide, the way PowerPoint
previews an animation, or click **Play Build** to play all of the build's steps. A pointer move starts from wherever
the build's earlier moves leave the pointer.

Click **Done**, or **Script** again, to return to the inspector.

## Voices

The bottom of the Script panel holds the voice settings, which apply to the whole deck:

- **Voice:** the system voice and the other text-to-speech voices installed on your Mac, plus voices from online
  services, marked with a sparkle. Add more system voices in **System Settings ▸ Accessibility ▸ Spoken Content**.
- **Speaking speed:** how fast the voice speaks.
- **Builds with no script stay up:** how many seconds a build without a script stays on screen.

### Online voices

Voices from ElevenLabs and OpenAI sound more natural than the system voices, but need an account with the service.
Choose one, click **Connect…**, and paste an API key; the sheet links to where to make one. Manimble checks the key
before keeping it, and stores it in your login keychain, never in the deck.

Speech from an online voice is cached, so replaying a show doesn't call the service (or cost anything) again.

## Play a scripted presentation

Choose **Play ▸ Scripted Presentation**, or **Play ▸ Scripted Presentation from Current Slide**. The show plays the
animations or the stills, following **Play ▸ Show Animations**.

- <kbd>Space</kbd> or <kbd>K</kbd> pauses and resumes.
- The arrow keys and clicks still move through the show; the script picks up on the build you reach.
- The show ends after the last slide, or when you press <kbd>Esc</kbd>.

## Export a scripted presentation as a movie

When the deck has a script, the movie export can include it: choose **File ▸ Export To ▸ Movie (.mp4, with
animations)…** and tick **Export with script** in the Save panel. Each build's clip plays, then its last frame is held
while the script runs, with the narration as the movie's soundtrack and the pointer drawn over the slide. See
[Exporting](../sharing/export.md#movie).
