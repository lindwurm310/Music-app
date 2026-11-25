"""ライブラリ・プレイリスト・アートワーク取得をまとめるサービス層。"""

from __future__ import annotations

import hashlib
import logging
import secrets
import socket
import threading
import time
import uuid
from dataclasses import dataclass
from pathlib import Path

from . import PROTOCOL_VERSION, __version__, artwork
from .library import Library
from .playlists import PlaylistStore

log = logging.getLogger(__name__)

TOKEN_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # 紛らわしい 0/O/1/I を除外
TOKEN_LENGTH = 10


@dataclass
class ArtworkReport:
    albums_checked: int = 0
    found: int = 0
    not_found: int = 0
    embedded_files: int = 0


class MusicSyncService:
    def __init__(self, library_root: Path | str, data_dir: Path | str | None = None,
                 http_get=None, rescan_interval: float = 10.0,
                 auto_artwork: bool = False, embed_artwork: bool = False):
        self.library = Library(library_root, data_dir)
        self.data_dir = self.library.data_dir
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.playlists = PlaylistStore(self.data_dir / "playlists.json")
        self.fetcher = artwork.ArtworkFetcher(self.data_dir / "art_misses.json", http_get=http_get)
        self.rescan_interval = rescan_interval
        self.auto_artwork = auto_artwork
        self.embed_artwork = embed_artwork
        self.server_id = self._load_or_create("server_id", lambda: str(uuid.uuid4()))
        self.token = self._load_or_create("token", self._new_token)
        self.server_name = socket.gethostname() or "MusicSync"
        self._scan_lock = threading.Lock()
        self._art_thread: threading.Thread | None = None

    # ------------------------------------------------------------ 設定ファイル
    @staticmethod
    def _new_token() -> str:
        return "".join(secrets.choice(TOKEN_ALPHABET) for _ in range(TOKEN_LENGTH))

    def _load_or_create(self, name: str, factory) -> str:
        path = self.data_dir / name
        try:
            value = path.read_text(encoding="utf-8").strip()
            if value:
                return value
        except FileNotFoundError:
            pass
        value = factory()
        path.write_text(value + "\n", encoding="utf-8")
        try:
            path.chmod(0o600)
        except OSError:
            pass
        return value

    def reset_token(self) -> str:
        self.token = self._new_token()
        path = self.data_dir / "token"
        path.write_text(self.token + "\n", encoding="utf-8")
        try:
            path.chmod(0o600)
        except OSError:
            pass
        return self.token

    def check_token(self, candidate: str | None) -> bool:
        if not candidate:
            return False
        # 入力ゆれ（小文字・空白・ハイフン）を許容
        cleaned = candidate.strip().upper().replace("-", "").replace(" ", "")
        return secrets.compare_digest(cleaned.encode(), self.token.encode())

    # ------------------------------------------------------------ スキャン
    def refresh(self, force: bool = False):
        """前回スキャンから一定時間経っていれば再スキャン（同時実行は 1 本だけ）。"""
        if not force and time.time() - self.library.last_scan < self.rescan_interval:
            return None
        if not self._scan_lock.acquire(blocking=force):
            return None
        try:
            result = self.library.scan()
        finally:
            self._scan_lock.release()
        if self.auto_artwork and (result.added or result.updated):
            self.start_background_artwork(embed=self.embed_artwork)
        return result

    def manifest(self) -> dict:
        self.refresh()
        tracks = [t.to_manifest() for t in self.library.tracks()]
        playlists = [p.to_json() for p in self.playlists.all(include_deleted=True)]
        h = hashlib.sha1()
        for t in tracks:
            h.update(f"{t['id']}:{t['sha256']}:{t['artworkId']}\n".encode())
        return {
            "protocol": PROTOCOL_VERSION,
            "serverVersion": __version__,
            "serverId": self.server_id,
            "serverName": self.server_name,
            "generatedAt": int(time.time() * 1000),
            "libraryVersion": h.hexdigest(),
            "tracks": tracks,
            "playlists": playlists,
        }

    # ------------------------------------------------------------ アートワーク
    def fill_artwork(self, embed: bool = False, force: bool = False,
                     online: bool = True) -> ArtworkReport:
        """アートの無いアルバムを検索して補完する。embed=True ならファイルにも書き込む。"""
        report = ArtworkReport()
        if online:
            for key, tracks in self.library.albums_missing_artwork().items():
                sample = tracks[0]
                report.albums_checked += 1
                data = self.fetcher.fetch(key, sample.album_artist or sample.artist,
                                          sample.album, force=force)
                if data and self.library.set_album_artwork(key, data):
                    report.found += 1
                    log.info("アルバムアート取得: %s / %s", sample.album_artist or sample.artist, sample.album)
                else:
                    report.not_found += 1
        if embed:
            for t in self.library.tracks():
                if t.embedded_artwork_id or not t.artwork_id:
                    continue
                art_path = self.library.artwork_path(t.artwork_id)
                if art_path and artwork.embed_artwork(self.library.file_path(t), art_path.read_bytes()):
                    report.embedded_files += 1
            if report.embedded_files:
                self.refresh(force=True)
        return report

    def start_background_artwork(self, embed: bool = False) -> None:
        if self._art_thread and self._art_thread.is_alive():
            return

        def run():
            try:
                report = self.fill_artwork(embed=embed)
                if report.albums_checked:
                    log.info("アート自動取得: %d 件中 %d 件取得", report.albums_checked, report.found)
            except Exception:
                log.exception("アート自動取得でエラー")

        self._art_thread = threading.Thread(target=run, name="artwork", daemon=True)
        self._art_thread.start()
