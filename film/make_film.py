#!/usr/bin/env python3
"""Makes the Mochi & Patch short film from film.json.

character sheets -> one keyframe per shot -> a Veo 3.1 clip per shot -> the finished cut

Without an API key, `kit` writes a page of copy-ready prompts for the Gemini app and
Flow; save what they make into from-gemini/ (S01.mp4, S12-frame.png, ...) and run
`assemble`, which needs no key.

Run from this folder with its environment:
  .venv/bin/python make_film.py kit                        prompt kit page in out/kit/
  .venv/bin/python make_film.py models                     models your key can use
  .venv/bin/python make_film.py script                     write SCRIPT.md from film.json
  .venv/bin/python make_film.py sheets    [--only mochi]   3D character sheets from the app art
  .venv/bin/python make_film.py keyframes [--only S01,S02] a still for each shot (first frame of the clip)
  .venv/bin/python make_film.py clips     [--only S03] [--quality fast|standard]
  .venv/bin/python make_film.py pick keyframe:S01 keyframes/S01-t2.png
  .venv/bin/python make_film.py assemble  [--quality fast|standard] [--music track.mp3]
  .venv/bin/python make_film.py spend

Every generation is a new take (S01-t1, S01-t2, ...). The latest take is used unless
picks.json names another one. The API key comes from $GEMINI_API_KEY or the Keychain
item "gemini-api-key" and is never printed or saved. Each paid call is logged in
spend.json, and a batch is refused if its estimate would pass budget_usd in film.json.
"""

import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

ROOT = Path(__file__).resolve().parent
FILM = json.loads((ROOT / "film.json").read_text())
SPEND = ROOT / "spend.json"
PICKS = ROOT / "picks.json"
MIME = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp"}
FONT = "/System/Library/Fonts/SFNSRounded.ttf"
# The Gemini app reads the film words in these prompts as a request for a video unless told otherwise.
STILL = "Create ONE STILL IMAGE (a single picture, NOT a video, no animation).\n\n"
LOUDNESS_TARGET = -16  # LUFS, a usual level for video shared online
_lock = threading.Lock()
_client = None


# Key, client, bookkeeping

def api_key():
    key = os.environ.get("GEMINI_API_KEY", "")
    if not key:
        found = subprocess.run(["security", "find-generic-password", "-s", "gemini-api-key", "-w"],
                               capture_output=True, text=True)
        key = found.stdout.strip()
    if not key:
        sys.exit('No API key found. Save it with:  security add-generic-password -a "$USER" -s gemini-api-key -w')
    return key


def client():
    global _client
    if _client is None:
        from google import genai
        _client = genai.Client(api_key=api_key())
    return _client


def load(path, default):
    return json.loads(path.read_text()) if path.exists() else default


def spent():
    return sum(entry["usd"] for entry in load(SPEND, []))


def check_budget(planned):
    total, budget = spent(), FILM["budget_usd"]
    if total + planned > budget:
        sys.exit(f"Stopped: this batch is about ${planned:.2f}, ${total:.2f} is already spent and budget_usd is "
                 f"${budget}. Raise budget_usd in film.json to go on.")
    print(f"This batch: about ${planned:.2f}. Spent so far: ${total:.2f} of ${budget}.")


def log_spend(kind, model, usd, file):
    with _lock:
        entries = load(SPEND, [])
        entries.append({"at": datetime.datetime.now().isoformat(timespec="seconds"), "kind": kind, "model": model,
                        "usd": round(usd, 3), "file": str(file.relative_to(ROOT))})
        SPEND.write_text(json.dumps(entries, indent=2) + "\n")


def takes(folder, stem):
    pattern = re.compile(rf"^{re.escape(stem)}-t(\d+)\.\w+$")
    found = [(int(m.group(1)), p) for p in (ROOT / folder).glob(f"{stem}-t*") if (m := pattern.match(p.name))]
    return [p for _, p in sorted(found)]


def next_take(folder, stem, ext):
    with _lock:
        (ROOT / folder).mkdir(parents=True, exist_ok=True)
        number = len(takes(folder, stem)) + 1
        path = ROOT / folder / f"{stem}-t{number}{ext}"
        while path.exists():
            number += 1
            path = ROOT / folder / f"{stem}-t{number}{ext}"
        path.touch()  # claims the name for parallel jobs
        return path


def chosen(key, folder, stem):
    picked = load(PICKS, {}).get(key)
    if picked:
        return ROOT / picked
    existing = [p for p in takes(folder, stem) if p.stat().st_size > 0]
    return existing[-1] if existing else None


def newest(key, patterns):
    """The picked file for `key`, else the most recently saved file matching any pattern."""
    picked = load(PICKS, {}).get(key)
    if picked:
        return ROOT / picked
    found = [p for pattern in patterns for p in ROOT.glob(pattern) if p.stat().st_size > 0]
    return max(found, key=lambda p: p.stat().st_mtime) if found else None


def run_jobs(jobs, workers):
    failures = []
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(job): name for name, job in jobs}
        for future in as_completed(futures):
            name = futures[future]
            try:
                print(f"  ✓ {name}: {future.result().relative_to(ROOT)}")
            except Exception as error:  # report every failed shot, keep the others
                failures.append(name)
                print(f"  ✗ {name}: {error}")
    print(f"Spent so far: ${spent():.2f} of ${FILM['budget_usd']}.")
    if failures:
        sys.exit(f"Failed: {', '.join(failures)} (run again with --only {','.join(failures)})")


# Prompts

def character(name):
    return FILM["characters"][name]


def sheet_prompt(name):
    source = ("Re-create the character from the attached reference images (flat 2D app art) as a fully modelled 3D "
              "character, keeping its exact shape, proportions, colours and face." if character(name)["refs"]
              else "Design this character.")
    return (f"{STILL}{FILM['style']}\n\nCharacter model sheet. {source}\n{character(name)['look']}\n\n"
            "Show the same character three times side by side on a plain warm-cream studio background: front view, "
            "three-quarter view and side view, full body, neutral friendly pose, even soft lighting. Only the "
            "character: no props, furniture, text or labels.")


def keyframe_prompt(shot):
    looks = "\n".join(character(c)["look"] for c in shot["characters"])
    return (f"{STILL}{FILM['style']}\n\nSetting: {FILM['locations'][shot['location']]['description']}\n\n"
            f"Shot: {shot['keyframe']}\n\nCharacters (match the attached character sheets exactly in shape, colour "
            f"and face):\n{looks}\n\nA cinematic 16:9 frame: make the picture exactly the wide landscape shape of the "
            "attached blank canvas. No text, captions, logos or watermarks.")


def clip_prompt(shot):
    looks = " ".join(character(c)["look"] for c in shot["characters"])
    lines = "\n".join(f'{character(who)["name"]}, in {character(who)["voice"]}, says: "{line}"'
                      for who, line in shot["dialogue"])
    return (f"{FILM['style']}\n\nSetting: {FILM['locations'][shot['location']]['description']}\n\n"
            f"Camera: {shot['camera']}\nAction: {shot['action']}\n\nCharacters: {looks}\n\n"
            f"Dialogue, in this order:\n{lines}\n{voices_note(shot)}\n\nSound effects: {shot['sfx']}.\n{FILM['audio_rule']}")


def voices_note(shot):
    """Veo gives a line to the biggest face in the frame unless told who stays quiet."""
    speakers = {who for who, _ in shot["dialogue"]}
    silent = [character(c)["name"] for c in shot["characters"] if c not in speakers]
    note = "Each line is spoken only by the character named."
    if silent:
        note += f" {' and '.join(silent)} {'says' if len(silent) == 1 else 'say'} nothing, mouth closed."
    return f"{note} {shot['audio_note']}" if shot.get("audio_note") else note


def gemini_clip_prompt(shot):
    """Shorter than clip_prompt: in Flow the starting frame already shows who is who."""
    lines = "\n".join(f'{character(who)["name"]}, {character(who)["tag"]}, in {character(who)["voice"]}: "{line}"'
                      for who, line in shot["dialogue"])
    return (f"{FILM['style_short']}\n\nCamera: {shot['camera']}\nAction: {shot['action']}\n\n"
            f"Dialogue, lip-synced, in this order:\n{lines}\n{voices_note(shot)}\n\n"
            f"Sound: {shot['sfx']}.\n{FILM['audio_rule']}")


# Generation

def image_part(path):
    from google.genai import types
    return types.Part.from_bytes(data=path.read_bytes(), mime_type=MIME[path.suffix.lower()])


def generate_image(prompt, refs, folder, stem):
    from google.genai import types
    model = FILM["models"]["image"]
    response = client().models.generate_content(
        model=model, contents=[prompt] + [image_part(r) for r in refs],
        config=types.GenerateContentConfig(response_modalities=["IMAGE"],
                                           image_config=types.ImageConfig(aspect_ratio="16:9", image_size="2K")))
    for candidate in response.candidates or []:
        for part in (candidate.content.parts if candidate.content else None) or []:
            if part.inline_data and part.inline_data.data:
                ext = {v: k for k, v in MIME.items()}.get(part.inline_data.mime_type, ".png")
                out = next_take(folder, stem, ext)
                out.write_bytes(part.inline_data.data)
                log_spend("image", model, FILM["pricing_estimate_usd"]["image"], out)
                return out
    reason = response.prompt_feedback or (response.candidates[0].finish_reason if response.candidates else "empty")
    raise RuntimeError(f"no image returned ({reason})")


def generate_clip(shot, keyframe, quality):
    from google.genai import types
    model = FILM["models"][f"video_{quality}"]
    seconds = shot.get("seconds", 8)
    config = types.GenerateVideosConfig(aspect_ratio="16:9", resolution="1080p", duration_seconds=seconds,
                                        negative_prompt=FILM["negative"], number_of_videos=1)
    if any(character(c).get("human") for c in shot["characters"]):
        config.person_generation = "allow_adult"
    operation = client().models.generate_videos(
        model=model, prompt=clip_prompt(shot), config=config,
        image=types.Image(image_bytes=keyframe.read_bytes(), mime_type=MIME[keyframe.suffix.lower()]))
    while not operation.done:
        time.sleep(10)
        operation = client().operations.get(operation)
    if operation.error:
        raise RuntimeError(operation.error.get("message", operation.error))
    result = operation.response or operation.result
    if not result or not result.generated_videos:
        raise RuntimeError(f"no video returned (filtered: {result.rai_media_filtered_reasons if result else 'unknown'})")
    video = result.generated_videos[0].video
    client().files.download(file=video)
    out = next_take("clips", f"{shot['id']}-{quality}", ".mp4")
    video.save(str(out))
    log_spend("clip", model, seconds * FILM["pricing_estimate_usd"]["video_per_second"][quality], out)
    return out


def selected(items, only):
    wanted = set(only.split(",")) if only else None
    return [item for item in items if wanted is None or item in wanted]


def cmd_sheets(args):
    names = selected(list(FILM["characters"]), args.only)
    check_budget(len(names) * args.takes * FILM["pricing_estimate_usd"]["image"])
    jobs = [(f"{n} take {t + 1}", lambda n=n: generate_image(sheet_prompt(n), [ROOT / r for r in character(n)["refs"]],
                                                              "reference/sheets", n))
            for n in names for t in range(args.takes)]
    run_jobs(jobs, workers=4)


def cmd_keyframes(args):
    shots = [s for s in FILM["shots"] if s["id"] in selected([s["id"] for s in FILM["shots"]], args.only)]
    sheets = {n: chosen(f"sheet:{n}", "reference/sheets", n) for n in FILM["characters"]}
    missing = sorted({c for s in shots for c in s["characters"] if not sheets[c]})
    if missing:
        sys.exit(f"Make character sheets first: make_film.py sheets --only {','.join(missing)}")
    check_budget(len(shots) * args.takes * FILM["pricing_estimate_usd"]["image"])
    jobs = [(f"{s['id']} take {t + 1}",
             lambda s=s: generate_image(keyframe_prompt(s), [sheets[c] for c in s["characters"]], "keyframes", s["id"]))
            for s in shots for t in range(args.takes)]
    run_jobs(jobs, workers=4)


def cmd_clips(args):
    shots = [s for s in FILM["shots"] if s["id"] in selected([s["id"] for s in FILM["shots"]], args.only)]
    frames = {s["id"]: chosen(f"keyframe:{s['id']}", "keyframes", s["id"]) for s in shots}
    missing = [i for i, f in frames.items() if not f]
    if missing:
        sys.exit(f"Make keyframes first: make_film.py keyframes --only {','.join(missing)}")
    rate = FILM["pricing_estimate_usd"]["video_per_second"][args.quality]
    check_budget(sum(s.get("seconds", 8) for s in shots) * args.takes * rate)
    jobs = [(f"{s['id']} take {t + 1}", lambda s=s: generate_clip(s, frames[s["id"]], args.quality))
            for s in shots for t in range(args.takes)]
    run_jobs(jobs, workers=args.parallel)


# Script, picks, spend, models

def cmd_script(_):
    out = [f"# {FILM['title']}\n", f"*{FILM['logline']}*\n",
           f"Runtime: about {sum(s.get('seconds', 8) for s in FILM['shots']) + FILM['end_card']['seconds']} seconds, "
           f"{len(FILM['shots'])} shots.\n", "## Characters\n"]
    out += [f"- **{c['name']}**: {c['look']} *Voice: {c['voice']}.*" for c in FILM["characters"].values()]
    out.append("\n## Screenplay\n")
    for shot in FILM["shots"]:
        out.append(f"### {shot['id']} · {shot['title']} ({shot.get('seconds', 8)} s)\n")
        out.append(f"**{FILM['locations'][shot['location']]['slug']}**\n")
        out.append(f"{shot['keyframe']}\n\n*Camera:* {shot['camera']}  \n*Action:* {shot['action']}\n")
        out += [f"> **{character(who)['name'].upper()}:** {line}  " for who, line in shot["dialogue"]]
        out.append(f"\n*Sound:* {shot['sfx']}.  \n*Shows:* {shot['shows']}\n")
    card = FILM["end_card"]
    out.append(f"### End card ({card['seconds']} s)\n\n**{card['title']}**, {card['subtitle']}  \n{card['tagline']}\n")
    (ROOT / "SCRIPT.md").write_text("\n".join(out))
    print("Wrote SCRIPT.md")


def cmd_kit(_):
    import shutil
    kit = ROOT / "out" / "kit"
    (kit / "refs").mkdir(parents=True, exist_ok=True)
    sheets = []
    for name, c in FILM["characters"].items():
        refs = []
        for ref in c["refs"]:
            shutil.copy(ROOT / ref, kit / "refs" / Path(ref).name)
            refs.append({"src": f"refs/{Path(ref).name}", "path": f"film/{ref}"})
        sheets.append({"id": name, "name": c["name"], "refs": refs, "prompt": sheet_prompt(name),
                       "save": f"sheet-{name}.png"})
    start = 0
    shots = []
    for shot in FILM["shots"]:
        seconds = shot.get("seconds", 8)
        shots.append({"id": shot["id"], "title": shot["title"], "shows": shot["shows"], "start": start,
                      "seconds": seconds, "slug": FILM["locations"][shot["location"]]["slug"],
                      "dialogue": [[character(who)["name"], line] for who, line in shot["dialogue"]],
                      # The Gemini app makes square images unless a wide image is attached.
                      "attach": [f"sheet-{c}.png" for c in shot["characters"]] + ["reference/canvas-16x9.png"],
                      "frame": keyframe_prompt(shot), "clip": gemini_clip_prompt(shot),
                      "saveFrame": f"{shot['id']}-frame.png", "saveClip": f"{shot['id']}.mp4"})
        start += seconds
    data = {"title": FILM["title"], "logline": FILM["logline"], "runtime": start + FILM["end_card"]["seconds"],
            "sheets": sheets, "shots": shots}
    page = (ROOT / "kit_template.html").read_text().replace(
        "/*DATA*/null", json.dumps(data, ensure_ascii=False).replace("</", "<\\/"))
    (kit / "index.html").write_text(page)
    print(f"Wrote {kit / 'index.html'}")


def cmd_pick(args):
    path = (ROOT / args.file).resolve()
    if not path.exists():
        sys.exit(f"No such file: {args.file}")
    picks = load(PICKS, {})
    picks[args.key] = str(path.relative_to(ROOT))
    PICKS.write_text(json.dumps(picks, indent=2) + "\n")
    print(f"{args.key} -> {picks[args.key]}")


def cmd_spend(_):
    entries = load(SPEND, [])
    for kind in sorted({e["kind"] for e in entries}):
        rows = [e for e in entries if e["kind"] == kind]
        print(f"{kind}: {len(rows)} made, about ${sum(e['usd'] for e in rows):.2f}")
    print(f"Total: about ${spent():.2f} of ${FILM['budget_usd']} (estimates; Google's billing page is the real number)")


def cmd_models(_):
    names = [m.name.removeprefix("models/") for m in client().models.list()]
    for name in names:
        if "veo" in name or "image" in name:
            print(name)
    for role, name in FILM["models"].items():
        print(f"{role}: {name} {'✓' if name in names else '✗ not available to this key'}")


# Assembly

def ffmpeg(*args):
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *map(str, args)], check=True)


def probe(path):
    info = json.loads(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration:stream=codec_type",
                                      "-of", "json", str(path)], capture_output=True, text=True, check=True).stdout)
    return float(info["format"]["duration"]), any(s["codec_type"] == "audio" for s in info["streams"])


def loudness(path):
    report = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", str(path), "-af", "ebur128", "-f", "null", "-"],
                            capture_output=True, text=True).stderr
    found = re.findall(r"I:\s+(-?[\d.]+) LUFS", report)
    return float(found[-1]) if found else None


def normalize(clip, out):
    duration, has_audio = probe(clip)
    video = "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,fps=24,format=yuv420p"
    # Each Veo clip comes out at its own level; bring every shot to the same loudness.
    measured = loudness(clip) if has_audio else None
    gain = min(max(LOUDNESS_TARGET - measured, -10), 10) if measured and measured > -70 else 0
    audio = (f"aresample=48000,volume={gain:.1f}dB,alimiter=limit=0.89:level=false,"
             f"afade=t=in:d=0.06,afade=t=out:st={max(duration - 0.12, 0):.2f}:d=0.12")
    inputs = ["-i", clip] if has_audio else ["-i", clip, "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo"]
    ffmpeg(*inputs, "-t", f"{duration:.3f}", "-vf", video, "-af", audio, "-ac", 2, "-c:v", "libx264", "-crf", 16,
           "-preset", "slow", "-c:a", "aac", "-b:a", "192k", out)
    return duration


def end_card(background, out_png):
    from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageFont
    image = (Image.open(background).convert("RGB").resize((1920, 1080)) if background
             else Image.new("RGB", (1920, 1080), (251, 244, 236)))
    image = ImageEnhance.Brightness(image.filter(ImageFilter.GaussianBlur(22))).enhance(0.42)
    draw = ImageDraw.Draw(image)
    card = FILM["end_card"]
    for text, size, weight, y in [(card["title"], 132, "Bold", 410), (card["subtitle"], 54, "Medium", 560),
                                  (card["tagline"], 34, "Regular", 650)]:
        font = ImageFont.truetype(FONT, size)
        try:
            font.set_variation_by_name(weight)
        except Exception:  # a static font has no named weights
            pass
        width = draw.textlength(text, font=font)
        draw.text(((1920 - width) / 2, y), text, font=font, fill=(255, 246, 236))
    image.save(out_png)


def srt_time(seconds):
    ms = round(seconds * 1000)
    return f"{ms // 3_600_000:02}:{ms // 60_000 % 60:02}:{ms // 1000 % 60:02},{ms % 1000:03}"


def cmd_assemble(args):
    work = ROOT / "out" / "work"
    work.mkdir(parents=True, exist_ok=True)
    parts, cues, start = [], [], 0.0
    for shot in FILM["shots"]:
        clip = newest(f"clip:{shot['id']}", [f"clips/{shot['id']}-{args.quality}-t*.mp4", f"from-gemini/{shot['id']}*.mp4"])
        if not clip and args.draft:
            print(f"  - {shot['id']}: no clip yet, skipped")
            continue
        if not clip:
            sys.exit(f"{shot['id']} has no clip yet: save it as from-gemini/{shot['id']}.mp4 (or use --draft)")
        part = work / f"{shot['id']}.mp4"
        duration = normalize(clip, part)
        words = [len(line.split()) for _, line in shot["dialogue"]]
        at, span = start + 0.4, duration - 0.8
        for (who, line), count in zip(shot["dialogue"], words):
            length = span * count / sum(words)
            cues.append((at, at + length, f"{character(who)['name']}: {line}"))
            at += length
        parts.append(part)
        start += duration
        print(f"  ✓ {shot['id']}: {clip.relative_to(ROOT)}")

    total = start
    if not args.draft:
        card_png, card_mp4 = work / "end-card.png", work / "end-card.mp4"
        end_card(newest("keyframe:S12", ["keyframes/S12-t*.*", "from-gemini/S12-frame*.*"]), card_png)
        ffmpeg("-loop", 1, "-i", card_png, "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo",
               "-t", FILM["end_card"]["seconds"], "-vf", "fps=24,format=yuv420p,fade=t=in:d=0.8", "-ac", 2,
               "-c:v", "libx264", "-crf", 16, "-c:a", "aac", "-b:a", "192k", card_mp4)
        parts.append(card_mp4)
        total += FILM["end_card"]["seconds"]

    listing = work / "parts.txt"
    listing.write_text("".join(f"file '{p}'\n" for p in parts))
    joined = work / "joined.mp4"
    ffmpeg("-f", "concat", "-safe", 0, "-i", listing, "-c", "copy", joined)

    srt = ROOT / "out" / "mochi-and-patch.srt"
    srt.write_text("\n".join(f"{i}\n{srt_time(a)} --> {srt_time(b)}\n{text}\n" for i, (a, b, text) in enumerate(cues, 1)))
    film = ROOT / "out" / f"mochi-and-patch{'-draft' if args.draft else ''}.mp4"
    if args.music:
        ffmpeg("-i", joined, "-i", srt, "-i", args.music, "-filter_complex",
               f"[2:a]volume={args.music_volume},afade=t=out:st={total - 3:.2f}:d=3[m];"
               "[0:a][m]amix=inputs=2:duration=first:normalize=0[a]",
               "-map", "0:v", "-map", "[a]", "-map", "1", "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
               "-c:s", "mov_text", "-metadata:s:s:0", "language=eng", film)
    else:
        ffmpeg("-i", joined, "-i", srt, "-map", 0, "-map", 1, "-c", "copy", "-c:s", "mov_text",
               "-metadata:s:s:0", "language=eng", film)
    print(f"Film: {film} ({total:.0f} s)\nSubtitles: {srt}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("models").set_defaults(run=cmd_models)
    commands.add_parser("script").set_defaults(run=cmd_script)
    commands.add_parser("kit").set_defaults(run=cmd_kit)
    commands.add_parser("spend").set_defaults(run=cmd_spend)
    for name, run in [("sheets", cmd_sheets), ("keyframes", cmd_keyframes)]:
        command = commands.add_parser(name)
        command.add_argument("--only")
        command.add_argument("--takes", type=int, default=1)
        command.set_defaults(run=run)
    clips = commands.add_parser("clips")
    clips.add_argument("--only")
    clips.add_argument("--takes", type=int, default=1)
    clips.add_argument("--quality", choices=["fast", "standard"], default="fast")
    clips.add_argument("--parallel", type=int, default=3)
    clips.set_defaults(run=cmd_clips)
    pick = commands.add_parser("pick")
    pick.add_argument("key", help="sheet:<character>, keyframe:<shot> or clip:<shot>")
    pick.add_argument("file")
    pick.set_defaults(run=cmd_pick)
    assemble = commands.add_parser("assemble")
    assemble.add_argument("--quality", choices=["fast", "standard"], default="fast")
    assemble.add_argument("--music")
    assemble.add_argument("--music-volume", type=float, default=0.18)
    assemble.add_argument("--draft", action="store_true", help="skip shots without a clip and the end card")
    assemble.set_defaults(run=cmd_assemble)
    args = parser.parse_args()
    os.chdir(ROOT)
    args.run(args)


if __name__ == "__main__":
    main()
