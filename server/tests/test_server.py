import hashlib
import json
import threading
import urllib.error
import urllib.request

import pytest
from conftest import make_audio, make_image, make_wav, needs_ffmpeg

from musicsync.server import make_server
from musicsync.service import MusicSyncService


@pytest.fixture
def running(music_dir):
    make_wav(music_dir / "Artist" / "Album" / "song.wav", seconds=1.0)
    svc = MusicSyncService(music_dir, rescan_interval=0)
    svc.refresh(force=True)
    server = make_server(svc, "127.0.0.1", 0)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{server.server_address[1]}"

    def call(method, path, body=None, token=svc.token, headers=None, raw=False):
        data = json.dumps(body).encode() if body is not None else None
        h = {"Content-Type": "application/json"}
        if token:
            h["Authorization"] = f"Bearer {token}"
        h.update(headers or {})
        req = urllib.request.Request(base + path, data=data, method=method, headers=h)
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                content = resp.read()
                return resp.status, dict(resp.headers), (content if raw else json.loads(content or b"null"))
        except urllib.error.HTTPError as e:
            content = e.read()
            try:
                parsed = json.loads(content) if content else None
            except ValueError:
                parsed = content
            return e.code, dict(e.headers), parsed

    yield svc, call, music_dir
    server.shutdown()
    server.server_close()


def test_ping_without_auth(running):
    svc, call, _ = running
    status, _, body = call("GET", "/api/ping", token=None)
    assert status == 200 and body["serverId"] == svc.server_id and body["protocol"] == 1


def test_auth_required(running):
    _, call, _ = running
    assert call("GET", "/api/manifest", token=None)[0] == 401
    assert call("GET", "/api/manifest", token="WRONG")[0] == 401


def test_token_input_is_forgiving(running):
    svc, call, _ = running
    t = svc.token.lower()
    assert call("GET", "/api/manifest", token=f" {t[:5]}-{t[5:]} ")[0] == 200


def test_manifest(running):
    svc, call, _ = running
    status, _, m = call("GET", "/api/manifest")
    assert status == 200
    assert m["serverId"] == svc.server_id
    [t] = m["tracks"]
    assert t["path"] == "Artist/Album/song.wav" and t["fileExtension"] == "wav"
    assert set(t) >= {"id", "sha256", "size", "title", "artist", "album", "artworkId", "duration"}
    v1 = m["libraryVersion"]
    assert call("GET", "/api/manifest")[2]["libraryVersion"] == v1


def test_manifest_picks_up_new_files(running):
    _, call, music = running
    make_wav(music / "new.wav")
    assert len(call("GET", "/api/manifest")[2]["tracks"]) == 2


def test_audio_download_and_ranges(running):
    svc, call, music = running
    [t] = call("GET", "/api/manifest")[2]["tracks"]
    full = (music / t["path"]).read_bytes()
    status, headers, body = call("GET", f"/api/tracks/{t['id']}/audio", raw=True)
    assert status == 200 and body == full
    assert hashlib.sha256(body).hexdigest() == t["sha256"]
    assert headers["Accept-Ranges"] == "bytes" and headers["Content-Type"] == "audio/wav"
    status, headers, body = call("GET", f"/api/tracks/{t['id']}/audio", headers={"Range": "bytes=10-19"}, raw=True)
    assert status == 206 and body == full[10:20]
    assert headers["Content-Range"] == f"bytes 10-19/{len(full)}"
    status, _, body = call("GET", f"/api/tracks/{t['id']}/audio", headers={"Range": "bytes=-5"}, raw=True)
    assert status == 206 and body == full[-5:]
    status, _, body = call("GET", f"/api/tracks/{t['id']}/audio", headers={"Range": f"bytes=100-{10**9}"}, raw=True)
    assert status == 206 and body == full[100:]
    assert call("GET", f"/api/tracks/{t['id']}/audio", headers={"Range": f"bytes={len(full)}-"})[0] == 416
    assert call("GET", f"/api/tracks/{t['id']}/audio", headers={"Range": "bytes=abc"})[0] == 416
    assert call("GET", "/api/tracks/0000000000000000/audio")[0] == 404
    assert call("GET", "/api/tracks/../../etc/audio")[0] == 404


def test_audio_file_deleted_after_scan(running):
    _, call, music = running
    [t] = call("GET", "/api/manifest")[2]["tracks"]
    (music / t["path"]).unlink()
    assert call("GET", f"/api/tracks/{t['id']}/audio")[0] == 404


def test_playlist_api(running):
    _, call, _ = running
    [t] = call("GET", "/api/manifest")[2]["tracks"]
    status, _, p = call("POST", "/api/playlists", {"name": "ドライブ", "trackIds": [t["id"]]})
    assert status == 201 and p["name"] == "ドライブ" and p["trackIds"] == [t["id"]]
    assert call("GET", f"/api/playlists/{p['id']}")[2]["name"] == "ドライブ"
    status, _, p2 = call("PUT", f"/api/playlists/{p['id']}", {"name": "通勤"})
    assert status == 200 and p2["name"] == "通勤" and p2["updatedAt"] > p["updatedAt"]
    assert [x["name"] for x in call("GET", "/api/playlists")[2]["playlists"]] == ["通勤"]
    assert call("DELETE", f"/api/playlists/{p['id']}")[0] == 200
    assert call("GET", f"/api/playlists/{p['id']}")[0] == 404
    assert call("DELETE", f"/api/playlists/{p['id']}")[0] == 404
    # 削除は manifest に tombstone として残る
    pls = call("GET", "/api/manifest")[2]["playlists"]
    assert pls[0]["deleted"] is True


def test_playlist_validation(running):
    _, call, _ = running
    assert call("POST", "/api/playlists", {"name": ""})[0] == 400
    assert call("POST", "/api/playlists", {"name": "x", "trackIds": "abc"})[0] == 400
    assert call("POST", "/api/playlists", [1, 2])[0] == 400
    assert call("PUT", "/api/playlists/nope", {"name": "x"})[0] == 404
    assert call("POST", "/api/playlists/sync", {"playlists": [{"id": "x", "trackIds": [1]}]})[0] == 400
    assert call("POST", "/api/playlists/sync", {})[0] == 400
    assert call("PATCH" if False else "PUT", "/api/manifest")[0] == 404


def test_invalid_json_body(running):
    svc, call, _ = running
    import urllib.request as u
    status, _, body = call("POST", "/api/playlists", None, headers={})
    assert status == 400  # 空ボディ → 名前なし


def test_playlist_sync_roundtrip(running):
    _, call, _ = running
    status, _, p = call("POST", "/api/playlists", {"name": "server"})
    client = [
        {"id": p["id"], "name": "edited on phone", "trackIds": [], "updatedAt": p["updatedAt"] + 1},
        {"id": "phone-new", "name": "new on phone", "trackIds": [], "updatedAt": p["updatedAt"]},
    ]
    status, _, body = call("POST", "/api/playlists/sync", {"playlists": client})
    assert status == 200
    names = sorted(x["name"] for x in body["playlists"])
    assert names == ["edited on phone", "new on phone"]


def test_rescan_endpoint(running):
    _, call, music = running
    make_wav(music / "x.wav")
    status, _, body = call("POST", "/api/rescan")
    assert status == 200 and body["added"] == 1


def test_web_ui(running):
    _, call, _ = running
    status, headers, body = call("GET", "/", token=None, raw=True)
    assert status == 200 and b"MusicSync" in body and "text/html" in headers["Content-Type"]


def test_unknown_path(running):
    _, call, _ = running
    assert call("GET", "/etc/passwd", token=None)[0] == 404
    assert call("GET", "/api/nope")[0] == 404


@needs_ffmpeg
def test_artwork_endpoint_and_auto_fetch(music_dir):
    make_audio(music_dir / "a.mp3", artist="Band", album="Record")
    img = make_image()
    itunes = json.dumps({"results": [{"collectionName": "Record", "artistName": "Band",
                                      "artworkUrl100": "https://img/100x100bb.jpg"}]}).encode()

    def http(url):
        return itunes if "itunes.apple.com" in url else img if url.startswith("https://img/") else None

    svc = MusicSyncService(music_dir, http_get=http)
    svc.refresh(force=True)
    assert svc.manifest()["tracks"][0]["artworkId"] is None
    report = svc.fill_artwork(embed=True)
    assert report.found == 1 and report.embedded_files == 1
    t = svc.manifest()["tracks"][0]
    assert t["artworkId"]
    # 埋め込み後はファイル内容が変わる → sha256 も変わり iPhone は再取得する
    lib_track = svc.library.get(t["id"])
    assert lib_track.embedded_artwork_id

    server = make_server(svc, "127.0.0.1", 0)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        url = f"http://127.0.0.1:{server.server_address[1]}/api/artwork/{t['artworkId']}?token={svc.token}"
        with urllib.request.urlopen(url, timeout=5) as r:
            assert r.headers["Content-Type"] == "image/jpeg" and r.read()[:3] == b"\xff\xd8\xff"
    finally:
        server.shutdown()
        server.server_close()


def test_token_reset(music_dir):
    svc = MusicSyncService(music_dir)
    old = svc.token
    new = svc.reset_token()
    assert new != old and len(new) == 10
    assert MusicSyncService(music_dir).token == new
    assert not svc.check_token(old)
