import io
import shutil
import subprocess
import wave
from pathlib import Path

import pytest

HAS_FFMPEG = shutil.which("ffmpeg") is not None
needs_ffmpeg = pytest.mark.skipif(not HAS_FFMPEG, reason="ffmpeg が必要")


def make_wav(path: Path, seconds: float = 0.2) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(8000)
        w.writeframes(b"\x00\x00" * int(8000 * seconds))
    return path


def make_audio(path: Path, title="Song", artist="Artist", album="Album",
               track=1, seconds=0.3, album_artist=None) -> Path:
    """ffmpeg でタグ付きの音声ファイルを作る。"""
    path.parent.mkdir(parents=True, exist_ok=True)
    meta = ["-metadata", f"title={title}", "-metadata", f"artist={artist}",
            "-metadata", f"album={album}", "-metadata", f"track={track}"]
    if album_artist:
        meta += ["-metadata", f"album_artist={album_artist}"]
    codec = {".mp3": ["-c:a", "libmp3lame", "-b:a", "32k"],
             ".m4a": ["-c:a", "aac", "-b:a", "32k"],
             ".flac": ["-c:a", "flac"]}[path.suffix]
    subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
         f"sine=frequency=440:duration={seconds}", "-ac", "1", "-ar", "22050",
         *codec, *meta, str(path)],
        check=True,
    )
    return path


def make_image(color=(200, 30, 60), size=(800, 800), fmt="JPEG") -> bytes:
    from PIL import Image

    buf = io.BytesIO()
    Image.new("RGB", size, color).save(buf, format=fmt)
    return buf.getvalue()


@pytest.fixture
def music_dir(tmp_path):
    root = tmp_path / "Music"
    root.mkdir()
    return root
