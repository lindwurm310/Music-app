"""アルバムアートの抽出・検索・オンライン取得・埋め込み。"""

from __future__ import annotations

import io
import json
import logging
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Callable, Optional

log = logging.getLogger(__name__)

MAX_ART_SIZE = 600
MAX_DOWNLOAD_BYTES = 10 * 1024 * 1024
USER_AGENT = "MusicSync/1.0 (personal music sync tool)"
FOLDER_IMAGE_NAMES = ("cover", "folder", "front", "album", "albumart", "albumartsmall")
IMAGE_EXTS = (".jpg", ".jpeg", ".png")

HttpGet = Callable[[str], Optional[bytes]]


# ---------------------------------------------------------------- 画像処理
def image_mime(data: bytes) -> str | None:
    if data[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    return None


def normalize_image(data: bytes | None) -> bytes | None:
    """画像を最大 600px の JPEG に揃える。Pillow が無ければ JPEG はそのまま通す。"""
    if not data:
        return None
    try:
        from PIL import Image
    except ImportError:
        return data if image_mime(data) == "image/jpeg" else None
    try:
        with Image.open(io.BytesIO(data)) as img:
            img.load()
            if img.mode not in ("RGB", "L"):
                background = Image.new("RGB", img.size, (255, 255, 255))
                rgba = img.convert("RGBA")
                background.paste(rgba, mask=rgba.split()[-1])
                img = background
            elif img.mode == "L":
                img = img.convert("RGB")
            img.thumbnail((MAX_ART_SIZE, MAX_ART_SIZE))
            out = io.BytesIO()
            img.save(out, format="JPEG", quality=88, optimize=True)
            return out.getvalue()
    except Exception as exc:
        log.debug("画像を読めません: %s", exc)
        return None


# ---------------------------------------------------------------- 埋め込みアート
def extract_embedded(path: Path) -> bytes | None:
    try:
        import mutagen
        from mutagen.flac import FLAC
        from mutagen.id3 import ID3
        from mutagen.mp4 import MP4

        f = mutagen.File(path)
    except Exception:
        return None
    if f is None:
        return None
    try:
        if isinstance(f, FLAC):
            pics = sorted(f.pictures, key=lambda p: p.type != 3)  # 3 = Front cover
            return pics[0].data if pics else None
        if isinstance(f, MP4):
            covers = (f.tags or {}).get("covr") or []
            return bytes(covers[0]) if covers else None
        tags = getattr(f, "tags", None)
        if isinstance(tags, ID3):
            apics = sorted(tags.getall("APIC"), key=lambda p: p.type != 3)
            return apics[0].data if apics else None
    except Exception as exc:
        log.debug("埋め込みアート読み込み失敗 %s: %s", path, exc)
    return None


def find_folder_image(directory: Path) -> Path | None:
    """cover.jpg / folder.jpg などのフォルダ画像を探す。"""
    try:
        images = [
            p for p in directory.iterdir()
            if p.is_file() and p.suffix.lower() in IMAGE_EXTS and not p.name.startswith(".")
        ]
    except OSError:
        return None
    if not images:
        return None
    by_stem = {p.stem.lower(): p for p in images}
    for name in FOLDER_IMAGE_NAMES:
        if name in by_stem:
            return by_stem[name]
    # Windows Media Player が作る AlbumArt_{GUID}_Large.jpg（隠しファイル属性だが名前は普通）
    wmp = sorted(p for stem, p in by_stem.items() if stem.startswith("albumart_") and stem.endswith("_large"))
    if wmp:
        return wmp[0]
    images = [p for p in images if not p.stem.lower().startswith("albumart_")]
    # 画像が 1 枚だけならそれをジャケットとみなす
    return images[0] if len(images) == 1 else None


def embed_artwork(path: Path, data: bytes) -> bool:
    """音楽ファイルにジャケット画像を書き込む。対応形式なら True。"""
    mime = image_mime(data) or "image/jpeg"
    suffix = path.suffix.lower()
    try:
        if suffix == ".mp3":
            from mutagen.id3 import APIC
            from mutagen.mp3 import MP3

            f = MP3(path)
            if f.tags is None:
                f.add_tags()
            f.tags.delall("APIC")
            f.tags.add(APIC(encoding=3, mime=mime, type=3, desc="Cover", data=data))
            f.save()
            return True
        if suffix in (".m4a", ".m4b"):
            from mutagen.mp4 import MP4, MP4Cover

            f = MP4(path)
            fmt = MP4Cover.FORMAT_PNG if mime == "image/png" else MP4Cover.FORMAT_JPEG
            if f.tags is None:
                f.add_tags()
            f.tags["covr"] = [MP4Cover(data, imageformat=fmt)]
            f.save()
            return True
        if suffix == ".flac":
            from mutagen.flac import FLAC, Picture

            f = FLAC(path)
            pic = Picture()
            pic.type = 3
            pic.mime = mime
            pic.desc = "Cover"
            pic.data = data
            f.clear_pictures()
            f.add_picture(pic)
            f.save()
            return True
        if suffix in (".aif", ".aiff", ".wav"):
            from mutagen.aiff import AIFF
            from mutagen.id3 import APIC
            from mutagen.wave import WAVE

            f = AIFF(path) if suffix != ".wav" else WAVE(path)
            if f.tags is None:
                f.add_tags()
            f.tags.delall("APIC")
            f.tags.add(APIC(encoding=3, mime=mime, type=3, desc="Cover", data=data))
            f.save()
            return True
    except Exception as exc:
        log.warning("アートを埋め込めません %s: %s", path, exc)
    return False


# ---------------------------------------------------------------- オンライン取得
def default_http_get(url: str, timeout: float = 15.0) -> bytes | None:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "*/*"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = resp.read(MAX_DOWNLOAD_BYTES + 1)
            if len(data) > MAX_DOWNLOAD_BYTES:
                return None
            return data
    except (urllib.error.URLError, TimeoutError, OSError, ValueError) as exc:
        log.debug("HTTP 失敗 %s: %s", url, exc)
        return None


def _norm(text: str) -> str:
    text = unicodedata.normalize("NFKC", text or "").casefold()
    # 括弧内の付記 (Remastered, Deluxe Edition 等) は比較から外す
    out, depth = [], 0
    for ch in text:
        if ch in "([（【":
            depth += 1
        elif ch in ")]）】":
            depth = max(0, depth - 1)
        elif depth == 0 and (ch.isalnum()):
            out.append(ch)
    return "".join(out)


def _similar(a: str, b: str, strict: bool = False) -> bool:
    """表記ゆれを吸収して比較。部分一致は長さが近い場合のみ許可（誤マッチ防止）。"""
    na, nb = _norm(a), _norm(b)
    if not na or not nb:
        return False
    if na == nb:
        return True
    if strict:
        return False
    short, long_ = sorted((na, nb), key=len)
    return short in long_ and len(short) >= 3 and len(short) / len(long_) >= 0.6


def search_itunes(artist: str, album: str, http_get: HttpGet) -> bytes | None:
    term = f"{artist} {album}".strip()
    for country in ("JP", "US"):
        query = urllib.parse.urlencode(
            {"term": term, "entity": "album", "limit": 10, "country": country}
        )
        raw = http_get(f"https://itunes.apple.com/search?{query}")
        if not raw:
            continue
        try:
            results = json.loads(raw.decode("utf-8")).get("results", [])
        except (ValueError, UnicodeDecodeError):
            continue
        for item in results:
            name = item.get("collectionName", "")
            item_artist = item.get("artistName", "")
            # アーティスト不明のときはアルバム名の完全一致のみ採用
            if not _similar(name, album, strict=not artist):
                continue
            if artist and not _similar(item_artist, artist):
                continue
            url = item.get("artworkUrl100")
            if not url:
                continue
            url = url.replace("100x100bb", f"{MAX_ART_SIZE}x{MAX_ART_SIZE}bb")
            data = http_get(url)
            if data and image_mime(data):
                return data
    return None


def search_musicbrainz(artist: str, album: str, http_get: HttpGet) -> bytes | None:
    def esc(s: str) -> str:
        return s.replace("\\", "\\\\").replace('"', '\\"')

    q = f'release:"{esc(album)}"'
    if artist:
        q += f' AND artist:"{esc(artist)}"'
    url = "https://musicbrainz.org/ws/2/release/?" + urllib.parse.urlencode(
        {"query": q, "fmt": "json", "limit": 5}
    )
    raw = http_get(url)
    if not raw:
        return None
    try:
        releases = json.loads(raw.decode("utf-8")).get("releases", [])
    except (ValueError, UnicodeDecodeError):
        return None
    for rel in releases:
        if not _similar(rel.get("title", ""), album, strict=not artist):
            continue
        mbid = rel.get("id")
        if not mbid:
            continue
        data = http_get(f"https://coverartarchive.org/release/{mbid}/front-500")
        if data and image_mime(data):
            return data
    return None


class RateLimitedHttp:
    """ホストごとに最小間隔を空けて呼ぶ（iTunes は約 20 回/分、MusicBrainz は 1 回/秒の制限）。"""

    DEFAULT_INTERVALS = {
        "itunes.apple.com": 3.1,
        "musicbrainz.org": 1.1,
        "coverartarchive.org": 0.5,
    }

    def __init__(self, http_get: HttpGet, intervals: dict[str, float] | None = None,
                 sleep: Callable[[float], None] = time.sleep):
        self.http_get = http_get
        self.intervals = self.DEFAULT_INTERVALS if intervals is None else intervals
        self.sleep = sleep
        self._last: dict[str, float] = {}
        self.responses = 0  # 何らかの応答があった回数（ネットワーク断の判定用）

    def __call__(self, url: str) -> bytes | None:
        host = urllib.parse.urlsplit(url).hostname or ""
        interval = self.intervals.get(host, 0.0)
        if interval:
            wait = self._last.get(host, 0.0) + interval - time.monotonic()
            if wait > 0:
                self.sleep(wait)
            self._last[host] = time.monotonic()
        data = self.http_get(url)
        if data is not None:
            self.responses += 1
        return data


class ArtworkFetcher:
    """見つからなかったアルバムは一定期間再検索しない（ネガティブキャッシュ）。
    ネットワークに繋がらなかった場合は「見つからない」と記録しない。"""

    RETRY_AFTER = 7 * 24 * 3600

    def __init__(self, cache_path: Path, http_get: HttpGet | None = None,
                 sources: tuple[str, ...] = ("itunes", "musicbrainz"),
                 rate_limits: dict[str, float] | None = None):
        from .storage import read_json

        self.cache_path = cache_path
        # テスト等で http_get を差し替えたときは既定ではレート制限しない
        if rate_limits is None and http_get is not None:
            rate_limits = {}
        self.http_get = RateLimitedHttp(http_get or default_http_get, rate_limits)
        self.sources = sources
        self.misses: dict[str, float] = read_json(cache_path, {})
        self.offline = False  # 直近の検索でどこからも応答が無かった

    def _save(self) -> None:
        from .storage import write_json

        write_json(self.cache_path, self.misses)

    def fetch(self, key: str, artist: str, album: str, force: bool = False) -> bytes | None:
        if not album:
            return None
        last_miss = self.misses.get(key)
        if not force and last_miss and time.time() - last_miss < self.RETRY_AFTER:
            return None
        before = self.http_get.responses
        data = None
        for source in self.sources:
            fn = search_itunes if source == "itunes" else search_musicbrainz
            try:
                data = fn(artist, album, self.http_get)
            except Exception as exc:  # 外部 API の想定外応答でも止めない
                log.debug("%s 検索失敗: %s", source, exc)
                data = None
            if data:
                break
        self.offline = self.http_get.responses == before
        if data:
            self.misses.pop(key, None)
        elif not self.offline:
            self.misses[key] = time.time()
        else:
            return None
        self._save()
        return data
