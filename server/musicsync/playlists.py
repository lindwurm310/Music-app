"""プレイリスト管理と iPhone との双方向マージ。

マージ規則（シンプルな Last-Writer-Wins）:
- プレイリスト単位で updatedAt が新しい方を採用（同時刻ならサーバー優先）
- 削除は tombstone (deleted=True) として残し、他端末にも削除を伝える
- 30 日を過ぎた tombstone は破棄
"""

from __future__ import annotations

import threading
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path

from .storage import read_json, write_json

TOMBSTONE_TTL_MS = 30 * 24 * 3600 * 1000
MAX_NAME_LENGTH = 200
MAX_TRACKS = 20000


def now_ms() -> int:
    return int(time.time() * 1000)


class PlaylistError(ValueError):
    pass


@dataclass
class Playlist:
    id: str
    name: str
    track_ids: list[str] = field(default_factory=list)
    updated_at: int = 0
    deleted: bool = False

    def to_json(self) -> dict:
        return {
            "id": self.id,
            "name": self.name,
            "trackIds": list(self.track_ids),
            "updatedAt": self.updated_at,
            "deleted": self.deleted,
        }

    @classmethod
    def from_json(cls, raw: dict) -> "Playlist":
        if not isinstance(raw, dict):
            raise PlaylistError("playlist must be an object")
        pid = raw.get("id")
        if not isinstance(pid, str) or not (1 <= len(pid) <= 64):
            raise PlaylistError("invalid playlist id")
        name = raw.get("name", "")
        if not isinstance(name, str):
            raise PlaylistError("invalid name")
        tracks = raw.get("trackIds", [])
        if not isinstance(tracks, list) or not all(isinstance(t, str) for t in tracks):
            raise PlaylistError("invalid trackIds")
        if len(tracks) > MAX_TRACKS:
            raise PlaylistError("too many tracks")
        updated = raw.get("updatedAt", 0)
        if isinstance(updated, bool) or not isinstance(updated, (int, float)):
            raise PlaylistError("invalid updatedAt")
        return cls(
            id=pid,
            name=clean_name(name, allow_empty=bool(raw.get("deleted"))),
            track_ids=list(tracks),
            updated_at=int(updated),
            deleted=bool(raw.get("deleted", False)),
        )


def clean_name(name: str, allow_empty: bool = False) -> str:
    name = " ".join(name.split())[:MAX_NAME_LENGTH]
    if not name and not allow_empty:
        raise PlaylistError("プレイリスト名が空です")
    return name


class PlaylistStore:
    def __init__(self, path: Path):
        self.path = path
        self._lock = threading.RLock()
        self._items: dict[str, Playlist] = {}
        for raw in read_json(path, []):
            try:
                p = Playlist.from_json(raw)
            except PlaylistError:
                continue
            self._items[p.id] = p

    def _save(self) -> None:
        self._purge()
        write_json(self.path, [p.to_json() for p in self._items.values()])

    def _purge(self) -> None:
        cutoff = now_ms() - TOMBSTONE_TTL_MS
        for pid in [p.id for p in self._items.values() if p.deleted and p.updated_at < cutoff]:
            del self._items[pid]

    def _touch(self, p: Playlist) -> None:
        # 端末間の時計ずれがあっても「今回の変更」が必ず新しくなるように単調増加させる
        p.updated_at = max(now_ms(), p.updated_at + 1)

    # ------------------------------------------------ 参照
    def all(self, include_deleted: bool = False) -> list[Playlist]:
        with self._lock:
            items = [p for p in self._items.values() if include_deleted or not p.deleted]
            return sorted(items, key=lambda p: (p.deleted, p.name.casefold(), p.id))

    def get(self, pid: str) -> Playlist | None:
        with self._lock:
            p = self._items.get(pid)
            return p if p and not p.deleted else None

    def find(self, id_or_name: str) -> Playlist | None:
        with self._lock:
            p = self.get(id_or_name)
            if p:
                return p
            matches = [x for x in self.all() if x.name.casefold() == id_or_name.casefold()]
            return matches[0] if len(matches) == 1 else None

    # ------------------------------------------------ 変更
    def create(self, name: str, track_ids: list[str] | None = None) -> Playlist:
        with self._lock:
            p = Playlist(id=str(uuid.uuid4()), name=clean_name(name),
                         track_ids=list(track_ids or [])[:MAX_TRACKS])
            self._touch(p)
            self._items[p.id] = p
            self._save()
            return p

    def update(self, pid: str, name: str | None = None,
               track_ids: list[str] | None = None) -> Playlist:
        with self._lock:
            p = self.get(pid)
            if not p:
                raise KeyError(pid)
            if name is not None:
                p.name = clean_name(name)
            if track_ids is not None:
                if len(track_ids) > MAX_TRACKS:
                    raise PlaylistError("too many tracks")
                p.track_ids = list(track_ids)
            self._touch(p)
            self._save()
            return p

    def add_tracks(self, pid: str, track_ids: list[str]) -> Playlist:
        with self._lock:
            p = self.get(pid)
            if not p:
                raise KeyError(pid)
            return self.update(pid, track_ids=p.track_ids + list(track_ids))

    def remove_tracks(self, pid: str, track_ids: list[str]) -> Playlist:
        with self._lock:
            p = self.get(pid)
            if not p:
                raise KeyError(pid)
            drop = set(track_ids)
            return self.update(pid, track_ids=[t for t in p.track_ids if t not in drop])

    def delete(self, pid: str) -> bool:
        with self._lock:
            p = self.get(pid)
            if not p:
                return False
            p.deleted = True
            p.track_ids = []
            self._touch(p)
            self._save()
            return True

    def merge(self, incoming: list[dict]) -> list[Playlist]:
        """クライアントのプレイリスト一覧をマージし、マージ後の全件（tombstone 含む）を返す。"""
        parsed = [Playlist.from_json(raw) for raw in incoming]  # 1 件でも不正なら全体を拒否
        with self._lock:
            changed = False
            for theirs in parsed:
                ours = self._items.get(theirs.id)
                if ours is None or theirs.updated_at > ours.updated_at:
                    if ours is None and theirs.deleted and theirs.updated_at < now_ms() - TOMBSTONE_TTL_MS:
                        continue
                    self._items[theirs.id] = theirs
                    changed = True
            if changed:
                self._save()
            return self.all(include_deleted=True)

    def remap_tracks(self, mapping: dict[str, str]) -> int:
        """曲 ID の付け替え（フォルダ移動時）。変更したプレイリスト数を返す。"""
        if not mapping:
            return 0
        with self._lock:
            changed = 0
            for p in self.all():
                new_ids = [mapping.get(t, t) for t in p.track_ids]
                if new_ids != p.track_ids:
                    p.track_ids = new_ids
                    self._touch(p)
                    changed += 1
            if changed:
                self._save()
            return changed

    def prune_missing_tracks(self, valid_ids: set[str]) -> int:
        """ライブラリから消えた曲をプレイリストから取り除く（明示的な操作）。"""
        with self._lock:
            count = 0
            for p in self.all():
                kept = [t for t in p.track_ids if t in valid_ids]
                if len(kept) != len(p.track_ids):
                    count += len(p.track_ids) - len(kept)
                    p.track_ids = kept
                    self._touch(p)
            if count:
                self._save()
            return count
