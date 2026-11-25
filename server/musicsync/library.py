"""音楽フォルダのスキャンとトラック情報の管理。

- 音楽ファイル（iPhone で再生可能な形式）だけを対象にする
- (サイズ, 更新時刻) が変わらないファイルは再ハッシュしない（高速な再スキャン）
- アルバムアートは「埋め込み > フォルダ画像 > オンライン取得」の順で解決する
"""

from __future__ import annotations

import hashlib
import logging
import os
import threading
import time
import unicodedata
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Iterable

from . import artwork
from .storage import read_json, write_bytes_atomic, write_json

log = logging.getLogger(__name__)

# iPhone (AVFoundation) で再生できる形式のみ
AUDIO_EXTENSIONS = {
    ".mp3": "audio/mpeg",
    ".m4a": "audio/mp4",
    ".m4b": "audio/mp4",
    ".aac": "audio/aac",
    ".wav": "audio/wav",
    ".aif": "audio/aiff",
    ".aiff": "audio/aiff",
    ".flac": "audio/flac",
    ".caf": "audio/x-caf",
}

INDEX_VERSION = 2


def normalize(text: str | None) -> str:
    """比較用の正規化（全角半角・大文字小文字・前後空白を吸収）。"""
    if not text:
        return ""
    return " ".join(unicodedata.normalize("NFKC", text).casefold().split())


def album_key(artist: str | None, album: str | None) -> str:
    return f"{normalize(artist)}\x1f{normalize(album)}"


def track_id_for(relpath: str) -> str:
    # macOS(NFD) と他OS(NFC) でファイル名の表現が違っても同じ ID になるよう正規化
    rel = unicodedata.normalize("NFC", relpath)
    return hashlib.sha1(rel.encode("utf-8")).hexdigest()[:16]


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


@dataclass
class Track:
    id: str
    path: str  # ライブラリルートからの相対パス (POSIX 区切り)
    size: int
    mtime_ns: int
    sha256: str
    title: str
    artist: str = ""
    album: str = ""
    album_artist: str = ""
    track_number: int = 0
    disc_number: int = 0
    year: int = 0
    genre: str = ""
    duration: float = 0.0
    embedded_artwork_id: str | None = None
    folder_artwork_id: str | None = None
    artwork_id: str | None = field(default=None)  # 実際に使うアート（解決済み）

    @property
    def album_key(self) -> str:
        return album_key(self.album_artist or self.artist, self.album)

    @property
    def content_type(self) -> str:
        return AUDIO_EXTENSIONS.get(Path(self.path).suffix.lower(), "application/octet-stream")

    def to_manifest(self) -> dict:
        return {
            "id": self.id,
            "path": self.path,
            "size": self.size,
            "sha256": self.sha256,
            "title": self.title,
            "artist": self.artist,
            "album": self.album,
            "albumArtist": self.album_artist,
            "trackNumber": self.track_number,
            "discNumber": self.disc_number,
            "year": self.year,
            "genre": self.genre,
            "duration": round(self.duration, 3),
            "artworkId": self.artwork_id,
            "fileExtension": Path(self.path).suffix.lower().lstrip("."),
        }


@dataclass
class ScanResult:
    added: int = 0
    updated: int = 0
    removed: int = 0
    unchanged: int = 0
    errors: int = 0

    @property
    def changed(self) -> bool:
        return bool(self.added or self.updated or self.removed)


def _parse_int(value: object) -> int:
    """'3/12' や '2001-05-01' から先頭の整数を取り出す。"""
    if value is None:
        return 0
    if isinstance(value, (list, tuple)):
        value = value[0] if value else ""
    if isinstance(value, tuple):
        value = value[0]
    s = str(value).strip()
    digits = ""
    for ch in s:
        if ch.isdigit():
            digits += ch
        elif digits:
            break
    try:
        return int(digits) if digits else 0
    except ValueError:
        return 0


def _first(tags, *keys: str) -> str:
    if not tags:
        return ""
    for key in keys:
        try:
            value = tags.get(key)
        except (KeyError, ValueError, TypeError):
            value = None
        if value:
            if isinstance(value, (list, tuple)):
                value = value[0]
            text = str(value).strip()
            if text:
                return text
    return ""


def read_metadata(path: Path) -> dict:
    """タグを読む。失敗してもファイル名から最低限の情報を返す。"""
    meta = {
        "title": path.stem,
        "artist": "",
        "album": "",
        "album_artist": "",
        "track_number": 0,
        "disc_number": 0,
        "year": 0,
        "genre": "",
        "duration": 0.0,
    }
    try:
        import mutagen

        f = mutagen.File(path, easy=True)
    except Exception as exc:  # 壊れたタグでもスキャン全体は止めない
        log.warning("タグを読めません %s: %s", path, exc)
        return meta
    if f is None:
        return meta
    tags = f.tags
    meta["title"] = _first(tags, "title") or path.stem
    meta["artist"] = _first(tags, "artist")
    meta["album"] = _first(tags, "album")
    meta["album_artist"] = _first(tags, "albumartist", "album artist", "album_artist")
    meta["track_number"] = _parse_int(_first(tags, "tracknumber"))
    meta["disc_number"] = _parse_int(_first(tags, "discnumber"))
    meta["year"] = _parse_int(_first(tags, "date", "year", "originaldate"))
    meta["genre"] = _first(tags, "genre")
    info = getattr(f, "info", None)
    if info is not None and getattr(info, "length", None):
        meta["duration"] = float(info.length)
    return meta


class Library:
    def __init__(self, root: Path | str, data_dir: Path | str | None = None):
        self.root = Path(root).expanduser().resolve()
        if not self.root.is_dir():
            raise FileNotFoundError(f"音楽フォルダが見つかりません: {self.root}")
        self.data_dir = Path(data_dir).expanduser().resolve() if data_dir else self.root / ".musicsync"
        self.art_dir = self.data_dir / "artwork"
        self.index_path = self.data_dir / "index.json"
        self.album_art_path = self.data_dir / "album_art.json"
        self._lock = threading.RLock()
        self._tracks: dict[str, Track] = {}
        self._album_art: dict[str, str] = {}
        self._folder_art_cache: dict[str, tuple[int, str | None]] = {}
        self.last_scan: float = 0.0
        self._load()

    # ---------- 永続化 ----------
    def _load(self) -> None:
        data = read_json(self.index_path, {})
        if data.get("version") == INDEX_VERSION:
            for raw in data.get("tracks", []):
                try:
                    t = Track(**raw)
                except TypeError:
                    continue
                self._tracks[t.id] = t
        self._album_art = read_json(self.album_art_path, {})

    def _save(self) -> None:
        write_json(
            self.index_path,
            {"version": INDEX_VERSION, "tracks": [asdict(t) for t in self._tracks.values()]},
        )
        write_json(self.album_art_path, self._album_art)

    # ---------- アートワーク保存 ----------
    def store_artwork(self, data: bytes) -> str | None:
        """画像を正規化して保存し、アートワーク ID（内容ハッシュ）を返す。"""
        jpeg = artwork.normalize_image(data)
        if not jpeg:
            return None
        art_id = hashlib.sha1(jpeg).hexdigest()[:20]
        path = self.art_dir / f"{art_id}.jpg"
        if not path.exists():
            write_bytes_atomic(path, jpeg)
        return art_id

    def artwork_path(self, art_id: str) -> Path | None:
        if not art_id or not all(c in "0123456789abcdef" for c in art_id):
            return None
        path = self.art_dir / f"{art_id}.jpg"
        return path if path.is_file() else None

    def set_album_artwork(self, key: str, data: bytes) -> str | None:
        with self._lock:
            art_id = self.store_artwork(data)
            if art_id:
                self._album_art[key] = art_id
                self._resolve_artwork()
                self._save()
            return art_id

    # ---------- スキャン ----------
    def iter_audio_files(self) -> Iterable[Path]:
        for dirpath, dirnames, filenames in os.walk(self.root, followlinks=False):
            # 隠しフォルダ（.musicsync など）は除外
            dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
            for name in sorted(filenames):
                if name.startswith("."):
                    continue
                if Path(name).suffix.lower() in AUDIO_EXTENSIONS:
                    yield Path(dirpath) / name

    def _folder_artwork(self, directory: Path) -> str | None:
        key = str(directory)
        try:
            mtime = directory.stat().st_mtime_ns
        except OSError:
            return None
        cached = self._folder_art_cache.get(key)
        if cached and cached[0] == mtime:
            return cached[1]
        art_id = None
        image = artwork.find_folder_image(directory)
        if image:
            try:
                art_id = self.store_artwork(image.read_bytes())
            except OSError:
                art_id = None
        self._folder_art_cache[key] = (mtime, art_id)
        return art_id

    def scan(self) -> ScanResult:
        with self._lock:
            result = ScanResult()
            seen: set[str] = set()
            by_path = {t.path: t for t in self._tracks.values()}
            for path in self.iter_audio_files():
                rel = path.relative_to(self.root).as_posix()
                tid = track_id_for(rel)
                seen.add(tid)
                try:
                    st = path.stat()
                except OSError:
                    result.errors += 1
                    continue
                existing = by_path.get(rel) or self._tracks.get(tid)
                folder_art = self._folder_artwork(path.parent)
                if existing and existing.size == st.st_size and existing.mtime_ns == st.st_mtime_ns:
                    existing.folder_artwork_id = folder_art
                    result.unchanged += 1
                    continue
                try:
                    digest = sha256_file(path)
                    meta = read_metadata(path)
                    embedded = artwork.extract_embedded(path)
                except OSError as exc:
                    log.warning("読み込み失敗 %s: %s", path, exc)
                    result.errors += 1
                    continue
                embedded_id = self.store_artwork(embedded) if embedded else None
                self._tracks[tid] = Track(
                    id=tid,
                    path=rel,
                    size=st.st_size,
                    mtime_ns=st.st_mtime_ns,
                    sha256=digest,
                    embedded_artwork_id=embedded_id,
                    folder_artwork_id=folder_art,
                    **meta,
                )
                if existing:
                    result.updated += 1
                else:
                    result.added += 1
            for tid in list(self._tracks):
                if tid not in seen:
                    del self._tracks[tid]
                    result.removed += 1
            self._resolve_artwork()
            self._save()
            self.last_scan = time.time()
            if result.changed:
                log.info(
                    "スキャン完了: 追加 %d / 更新 %d / 削除 %d",
                    result.added, result.updated, result.removed,
                )
            return result

    def _resolve_artwork(self) -> None:
        # 同じアルバムで 1 曲でも埋め込みアートがあれば、他の曲にも流用する
        album_embedded: dict[str, str] = {}
        for t in self._tracks.values():
            if t.embedded_artwork_id and t.album:
                album_embedded.setdefault(t.album_key, t.embedded_artwork_id)
        for t in self._tracks.values():
            t.artwork_id = (
                t.embedded_artwork_id
                or t.folder_artwork_id
                or (album_embedded.get(t.album_key) if t.album else None)
                or (self._album_art.get(t.album_key) if t.album else None)
            )

    # ---------- 参照 ----------
    def tracks(self) -> list[Track]:
        with self._lock:
            return sorted(
                self._tracks.values(),
                key=lambda t: (
                    normalize(t.album_artist or t.artist),
                    normalize(t.album),
                    t.disc_number,
                    t.track_number,
                    normalize(t.title),
                ),
            )

    def get(self, track_id: str) -> Track | None:
        with self._lock:
            return self._tracks.get(track_id)

    def file_path(self, track: Track) -> Path:
        path = (self.root / track.path).resolve()
        # パストラバーサル防止
        if self.root not in path.parents:
            raise PermissionError(track.path)
        return path

    def albums_missing_artwork(self) -> dict[str, list[Track]]:
        with self._lock:
            missing: dict[str, list[Track]] = {}
            for t in self._tracks.values():
                if not t.artwork_id and t.album:
                    missing.setdefault(t.album_key, []).append(t)
            return missing
