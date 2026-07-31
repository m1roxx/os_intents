"""Assembles the README demo GIF from simulator screenshots.

Keyframes rather than a screen recording: there is no video encoder on this
machine, and three chosen moments read better in a README than a blurry clip.
Each frame carries its own caption so the picture does not need the prose
around it to be understood — and so the claim it makes is the one that was
actually measured.

The assembled GIF is committed; the three source frames are not — 857 KB of
input to a script nobody but the author runs. Re-capture them from a run of
`probe/run_integration.sh` if the demo ever needs rebuilding.

    python3 tool/make_demo_gif.py <frames-dir> docs/media/shortcuts_demo.gif
"""
import sys
from PIL import Image, ImageDraw, ImageFont

SRC = sys.argv[1]
OUT = sys.argv[2]

FRAMES = [
    ("01_library", "Two actions declared in Dart, offered by iOS", 1600),
    ("02_prompt_filled", "iOS asks — using the prompt written in Dart", 1700),
    ("03_result", "The handler answered. The app never opened.", 3000),
]

WIDTH = 380           # readable in a README without dominating it
CAPTION_H = 62
BG = (250, 250, 252)
FG = (24, 24, 27)
ACCENT = (10, 110, 240)

font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 17)

frames, durations = [], []
for name, caption, ms in FRAMES:
    shot = Image.open(f"{SRC}/{name}.png").convert("RGB")
    # The lower third of the screen is empty in every frame; cropping it keeps
    # the GIF readable at README width instead of mostly background.
    shot = shot.crop((0, 0, shot.width, int(shot.height * 0.72)))
    scale = WIDTH / shot.width
    shot = shot.resize((WIDTH, int(shot.height * scale)), Image.LANCZOS)

    canvas = Image.new("RGB", (WIDTH, shot.height + CAPTION_H), BG)
    canvas.paste(shot, (0, 0))

    draw = ImageDraw.Draw(canvas)
    draw.line([(0, shot.height), (WIDTH, shot.height)], fill=(226, 226, 232))
    # A rule under the caption, in the accent colour, as a progress hint.
    step = FRAMES.index((name, caption, ms)) + 1
    draw.line(
        [(0, shot.height + CAPTION_H - 3),
         (WIDTH * step / len(FRAMES), shot.height + CAPTION_H - 3)],
        fill=ACCENT, width=3,
    )
    box = draw.textbbox((0, 0), caption, font=font)
    draw.text(
        ((WIDTH - (box[2] - box[0])) / 2, shot.height + 18),
        caption, font=font, fill=FG,
    )

    frames.append(canvas.convert("P", palette=Image.ADAPTIVE, colors=128))
    durations.append(ms)

frames[0].save(
    OUT, save_all=True, append_images=frames[1:],
    duration=durations, loop=0, optimize=True, disposal=2,
)
print("wrote", OUT)
