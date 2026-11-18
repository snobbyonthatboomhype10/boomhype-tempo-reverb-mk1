#!/usr/bin/env python3
# Converts the embedded .woff2 fonts (Josefin Sans, Bevan - SIL OFL) to .ttf so JUCE can load them.
import os, subprocess, sys

def ensure():
    try:
        import fontTools, brotli  # noqa
        return
    except ImportError:
        pass
    for extra in ([], ["--break-system-packages"], ["--user"]):
        r = subprocess.run([sys.executable, "-m", "pip", "install", "--quiet", "fonttools", "brotli"] + extra)
        if r.returncode == 0:
            break
    import fontTools, brotli  # noqa

def main():
    src, dst = sys.argv[1], sys.argv[2]
    ensure()
    from fontTools.ttLib import TTFont
    os.makedirs(dst, exist_ok=True)
    for f in sorted(os.listdir(src)):
        if f.endswith(".woff2"):
            t = TTFont(os.path.join(src, f)); t.flavor = None
            t.save(os.path.join(dst, f[:-6] + ".ttf")); print("font:", f)

if __name__ == "__main__":
    main()
