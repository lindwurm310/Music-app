"""iOS アプリ (Swift) のモデル定義とサーバーの JSON キーが一致しているか確認する。"""

import re
from pathlib import Path

from conftest import make_wav

from musicsync.service import MusicSyncService

MODELS = Path(__file__).resolve().parents[2] / "ios" / "MusicSyncCore" / "Sources" / "MusicSyncCore" / "Models.swift"


def swift_struct_fields(name: str) -> set[str]:
    src = MODELS.read_text(encoding="utf-8")
    m = re.search(rf"public struct {name}\b[^{{]*\{{(.*?)\n\}}", src, re.S)
    assert m, name
    body = m.group(1)
    # ネストした init / 関数の中は除外し、トップレベルの stored property だけ拾う
    fields, depth = set(), 0
    for line in body.splitlines():
        if depth == 0:
            pm = re.match(r"\s*public var (\w+): [^{]+$", line)
            if pm:
                fields.add(pm.group(1))
        depth += line.count("{") - line.count("}")
    return fields


def test_track_and_playlist_keys_match_swift(tmp_path):
    root = tmp_path / "M"
    make_wav(root / "a.wav")
    svc = MusicSyncService(root)
    svc.playlists.create("x")
    m = svc.manifest()
    assert set(m["tracks"][0]) == swift_struct_fields("Track")
    assert set(m["playlists"][0]) == swift_struct_fields("Playlist")
    manifest_fields = swift_struct_fields("Manifest") - {"protocolVersion"} | {"protocol"}
    assert set(m) == manifest_fields
