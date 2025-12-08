#!/usr/bin/env python3
"""Generate icons for Whisper Voice app."""

from PIL import Image, ImageDraw
import os
import subprocess

ICONS_DIR = os.path.join(os.path.dirname(__file__), "icons")
os.makedirs(ICONS_DIR, exist_ok=True)


def draw_microphone(draw, size, color, filled=True):
    """Draw a microphone icon."""
    w, h = size, size

    # Scale factors
    s = size / 16

    # Microphone body (pill shape)
    body_left = int(5 * s)
    body_right = int(11 * s)
    body_top = int(2 * s)
    body_bottom = int(9 * s)

    if filled:
        # Filled microphone body
        draw.ellipse([body_left, body_top, body_right, body_top + 4*s], fill=color)
        draw.rectangle([body_left, body_top + 2*s, body_right, body_bottom - 2*s], fill=color)
        draw.ellipse([body_left, body_bottom - 4*s, body_right, body_bottom], fill=color)
    else:
        # Outline only
        draw.ellipse([body_left, body_top, body_right, body_top + 4*s], outline=color, width=max(1, int(s)))
        draw.rectangle([body_left, body_top + 2*s, body_right, body_bottom - 2*s], outline=color, width=max(1, int(s)))
        draw.ellipse([body_left, body_bottom - 4*s, body_right, body_bottom], outline=color, width=max(1, int(s)))

    # Stand arc
    arc_left = int(3 * s)
    arc_right = int(13 * s)
    arc_top = int(5 * s)
    arc_bottom = int(12 * s)
    draw.arc([arc_left, arc_top, arc_right, arc_bottom], start=0, end=180, fill=color, width=max(1, int(1.5*s)))

    # Stand line
    stand_x = int(8 * s)
    stand_top = int(11 * s)
    stand_bottom = int(14 * s)
    draw.line([stand_x, stand_top, stand_x, stand_bottom], fill=color, width=max(1, int(1.5*s)))

    # Base
    base_left = int(5 * s)
    base_right = int(11 * s)
    base_y = int(13.5 * s)
    draw.line([base_left, base_y, base_right, base_y], fill=color, width=max(1, int(1.5*s)))


def draw_recording_dot(draw, size, color):
    """Draw a recording indicator (red dot)."""
    s = size / 16
    center = size // 2
    radius = int(3 * s)
    draw.ellipse([center - radius, center - radius, center + radius, center + radius], fill=color)


def draw_hourglass(draw, size, color):
    """Draw an hourglass/loading icon."""
    w, h = size, size
    s = size / 16

    # Hourglass shape using triangles
    top_left = int(4 * s)
    top_right = int(12 * s)
    top_y = int(2 * s)
    middle_y = int(8 * s)
    bottom_y = int(14 * s)
    center_x = int(8 * s)

    # Top triangle
    draw.polygon([
        (top_left, top_y),
        (top_right, top_y),
        (center_x, middle_y)
    ], fill=color)

    # Bottom triangle
    draw.polygon([
        (center_x, middle_y),
        (top_left, bottom_y),
        (top_right, bottom_y)
    ], fill=color)

    # Top and bottom lines
    draw.line([top_left - s, top_y, top_right + s, top_y], fill=color, width=max(1, int(1.5*s)))
    draw.line([top_left - s, bottom_y, top_right + s, bottom_y], fill=color, width=max(1, int(1.5*s)))


def create_menubar_icon(name, draw_func, sizes=[16, 32]):
    """Create menu bar template icons (black on transparent)."""
    for size in sizes:
        img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        draw = ImageDraw.Draw(img)
        draw_func(draw, size, (0, 0, 0, 255))  # Black for template

        suffix = "@2x" if size == 32 else ""
        filename = f"{name}{suffix}.png"
        img.save(os.path.join(ICONS_DIR, filename))
        print(f"  Created {filename}")


def create_app_icon():
    """Create the app icon with multiple sizes for .icns."""
    sizes = [16, 32, 64, 128, 256, 512, 1024]

    iconset_dir = os.path.join(ICONS_DIR, "AppIcon.iconset")
    os.makedirs(iconset_dir, exist_ok=True)

    for size in sizes:
        # Create icon with gradient background
        img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        draw = ImageDraw.Draw(img)

        # Rounded rectangle background (blue gradient effect)
        margin = size // 8
        radius = size // 5

        # Draw rounded rectangle background
        bg_color = (59, 130, 246, 255)  # Blue
        draw.rounded_rectangle(
            [margin, margin, size - margin, size - margin],
            radius=radius,
            fill=bg_color
        )

        # Draw white microphone on top
        # Create a smaller canvas for the microphone
        mic_size = size - margin * 4
        mic_img = Image.new("RGBA", (mic_size, mic_size), (0, 0, 0, 0))
        mic_draw = ImageDraw.Draw(mic_img)
        draw_microphone(mic_draw, mic_size, (255, 255, 255, 255), filled=True)

        # Paste microphone centered
        offset = (size - mic_size) // 2
        img.paste(mic_img, (offset, offset), mic_img)

        # Save for iconset
        img.save(os.path.join(iconset_dir, f"icon_{size}x{size}.png"))

        # Also save @2x versions for retina
        if size <= 512:
            img.save(os.path.join(iconset_dir, f"icon_{size//2}x{size//2}@2x.png"))

    print(f"  Created iconset in {iconset_dir}")

    # Convert to .icns using iconutil (macOS)
    icns_path = os.path.join(ICONS_DIR, "AppIcon.icns")
    try:
        subprocess.run(
            ["iconutil", "-c", "icns", iconset_dir, "-o", icns_path],
            check=True,
            capture_output=True
        )
        print(f"  Created AppIcon.icns")
    except subprocess.CalledProcessError as e:
        print(f"  Warning: Could not create .icns file: {e}")
    except FileNotFoundError:
        print("  Warning: iconutil not found, .icns not created")


def main():
    print("Generating Whisper Voice icons...")
    print()

    print("Menu bar icons:")

    # Idle icon (microphone)
    create_menubar_icon("mic_idle", lambda d, s, c: draw_microphone(d, s, c, filled=True))

    # Recording icon (filled circle)
    create_menubar_icon("mic_recording", draw_recording_dot)

    # Transcribing icon (hourglass)
    create_menubar_icon("mic_transcribing", draw_hourglass)

    print()
    print("App icon:")
    create_app_icon()

    print()
    print("Done! Icons saved to:", ICONS_DIR)


if __name__ == "__main__":
    main()
