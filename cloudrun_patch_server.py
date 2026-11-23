#!/usr/bin/env python3
"""Apply the CloudRun audio-cleanup patch to an OpenPronounce checkout."""

from pathlib import Path
import re
import sys

MARKER = "# cloudrun: remove converted user audio"

# Match the /pronunciation body across upstream formatting changes: the return
# call may be on one line or wrapped over several lines.
PATTERN = re.compile(
    r"(?P<indent>[ \t]+)wav_file = _save_upload_as_wav\(file\)\r?\n"
    r"(?P=indent)sound = audio\.load\(wav_file\)\r?\n"
    r"(?P=indent)return speech\.compare_audio_with_text\(\s*"
    r"sound,\s*expected_text,\s*lang=lang\s*\)"
)


def build_patched_block(indent: str) -> str:
    inner = indent + "    "
    deeper = inner + "    "
    return (
        f"{indent}{MARKER}\n"
        f"{indent}wav_file = _save_upload_as_wav(file)\n"
        f"{indent}try:\n"
        f"{inner}sound = audio.load(wav_file)\n"
        f"{inner}return speech.compare_audio_with_text(\n"
        f"{deeper}sound, expected_text, lang=lang\n"
        f"{inner})\n"
        f"{indent}finally:\n"
        f"{inner}try:\n"
        f"{deeper}os.remove(wav_file)\n"
        f"{inner}except OSError:\n"
        f"{deeper}pass"
    )


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: cloudrun_patch_server.py /path/to/server.py", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    if not path.is_file():
        print(f"server.py not found: {path}", file=sys.stderr)
        return 2

    source = path.read_text(encoding="utf-8")
    if MARKER in source:
        print("audio cleanup patch already present")
        return 0

    matches = list(PATTERN.finditer(source))
    if len(matches) != 1:
        print(
            "cannot apply audio cleanup patch: expected 1 matching "
            f"/pronunciation block, found {len(matches)}",
            file=sys.stderr,
        )
        for number, line in enumerate(source.splitlines(), 1):
            if "wav_file" in line or "compare_audio_with_text" in line:
                print(f"  line {number}: {line}", file=sys.stderr)
        return 1

    match = matches[0]
    patched = (
        source[: match.start()]
        + build_patched_block(match.group("indent"))
        + source[match.end() :]
    )
    path.write_text(patched, encoding="utf-8")
    print(f"audio cleanup patch applied to {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
