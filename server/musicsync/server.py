"""iPhone アプリ向け HTTP API（標準ライブラリのみ）。

認証: `Authorization: Bearer <token>`（Web 画面用に `?token=` も可）

GET    /api/ping                     認証不要。サーバー情報
GET    /api/manifest                 全トラック + プレイリスト
GET    /api/tracks/<id>/audio        音声ファイル（Range 対応）
GET    /api/artwork/<artworkId>      JPEG
GET    /api/playlists                プレイリスト一覧
POST   /api/playlists                {name, trackIds?} 作成
PUT    /api/playlists/<id>           {name?, trackIds?} 更新
DELETE /api/playlists/<id>           削除
POST   /api/playlists/sync           {playlists:[...]} 双方向マージ
POST   /api/rescan                   再スキャン
"""

from __future__ import annotations

import json
import logging
import re
import os
import socket
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from importlib import resources
from urllib.parse import parse_qs, urlsplit

from . import PROTOCOL_VERSION, __version__
from .playlists import PlaylistError
from .service import MusicSyncService

log = logging.getLogger(__name__)

MAX_BODY = 8 * 1024 * 1024
RANGE_RE = re.compile(r"^bytes=(\d*)-(\d*)$")
TRACK_AUDIO_RE = re.compile(r"^/api/tracks/([0-9a-f]{16})/audio$")
ARTWORK_RE = re.compile(r"^/api/artwork/([0-9a-f]{1,64})$")
PLAYLIST_RE = re.compile(r"^/api/playlists/([A-Za-z0-9-]{1,64})$")


class HTTPError(Exception):
    def __init__(self, status: HTTPStatus, message: str = ""):
        super().__init__(message)
        self.status = status
        self.message = message or status.phrase


class Handler(BaseHTTPRequestHandler):
    server_version = f"MusicSync/{__version__}"
    protocol_version = "HTTP/1.1"
    service: MusicSyncService  # make_server で差し込む

    # ------------------------------------------------------------ 共通
    def log_message(self, fmt, *args):  # noqa: D401 - 標準ログに流す
        log.debug("%s - %s", self.address_string(), fmt % args)

    def _send_json(self, data, status: HTTPStatus = HTTPStatus.OK) -> None:
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _send_error(self, status: HTTPStatus, message: str) -> None:
        self._send_json({"error": message}, status)

    def _read_json(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            raise HTTPError(HTTPStatus.BAD_REQUEST, "invalid Content-Length")
        if length < 0:
            raise HTTPError(HTTPStatus.BAD_REQUEST, "invalid Content-Length")
        if length > MAX_BODY:
            raise HTTPError(HTTPStatus.REQUEST_ENTITY_TOO_LARGE)
        raw = self.rfile.read(length) if length else b""
        self._body_consumed = True
        if not raw:
            return {}
        try:
            return json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise HTTPError(HTTPStatus.BAD_REQUEST, "invalid JSON")

    def _query(self) -> dict[str, list[str]]:
        return parse_qs(urlsplit(self.path).query)

    def _authorized(self) -> bool:
        auth = self.headers.get("Authorization", "")
        if auth.lower().startswith("bearer "):
            return self.service.check_token(auth[7:])
        token = (self._query().get("token") or [None])[0]
        return self.service.check_token(token)

    def _dispatch(self, method: str) -> None:
        self._body_consumed = False
        path = urlsplit(self.path).path
        try:
            if method in ("GET", "HEAD") and path == "/api/ping":
                return self._send_json({
                    "app": "MusicSync",
                    "protocol": PROTOCOL_VERSION,
                    "serverVersion": __version__,
                    "serverId": self.service.server_id,
                    "serverName": self.service.server_name,
                })
            if method in ("GET", "HEAD") and path in ("/", "/index.html"):
                return self._send_web_ui()
            if not path.startswith("/api/"):
                raise HTTPError(HTTPStatus.NOT_FOUND)
            if not self._authorized():
                raise HTTPError(HTTPStatus.UNAUTHORIZED, "トークンが違います")
            self._route(method, path)
        except HTTPError as exc:
            self._drain_body()
            self._send_error(exc.status, exc.message)
        except (BrokenPipeError, ConnectionResetError):
            pass  # iPhone 側がダウンロードを中断した
        except Exception:
            log.exception("リクエスト処理エラー %s %s", method, path)
            try:
                self._send_error(HTTPStatus.INTERNAL_SERVER_ERROR, "internal error")
            except OSError:
                pass

    def _drain_body(self) -> None:
        """未読のリクエスト本文を読み捨てて keep-alive を壊さない。"""
        if getattr(self, "_body_consumed", False):
            return
        self._body_consumed = True
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if 0 < length <= MAX_BODY:
            try:
                self.rfile.read(length)
            except OSError:
                pass
        elif length > MAX_BODY:
            self.close_connection = True

    def do_GET(self):
        self._dispatch("GET")

    def do_HEAD(self):
        self._dispatch("HEAD")

    def do_POST(self):
        self._dispatch("POST")

    def do_PUT(self):
        self._dispatch("PUT")

    def do_DELETE(self):
        self._dispatch("DELETE")

    # ------------------------------------------------------------ ルーティング
    def _route(self, method: str, path: str) -> None:
        svc = self.service
        if path == "/api/manifest" and method in ("GET", "HEAD"):
            return self._send_json(svc.manifest())

        if m := TRACK_AUDIO_RE.match(path):
            if method not in ("GET", "HEAD"):
                raise HTTPError(HTTPStatus.METHOD_NOT_ALLOWED)
            return self._send_track(m.group(1))

        if m := ARTWORK_RE.match(path):
            if method not in ("GET", "HEAD"):
                raise HTTPError(HTTPStatus.METHOD_NOT_ALLOWED)
            art = svc.library.artwork_path(m.group(1))
            if not art:
                raise HTTPError(HTTPStatus.NOT_FOUND, "artwork not found")
            return self._send_file(art, "image/jpeg", cache=True)

        if path == "/api/playlists":
            if method == "GET":
                return self._send_json({"playlists": [p.to_json() for p in svc.playlists.all()]})
            if method == "POST":
                body = self._read_json()
                if not isinstance(body, dict):
                    raise HTTPError(HTTPStatus.BAD_REQUEST, "object expected")
                track_ids = body.get("trackIds") or []
                if not isinstance(track_ids, list) or not all(isinstance(t, str) for t in track_ids):
                    raise HTTPError(HTTPStatus.BAD_REQUEST, "invalid trackIds")
                try:
                    p = svc.playlists.create(str(body.get("name", "")), track_ids)
                except PlaylistError as exc:
                    raise HTTPError(HTTPStatus.BAD_REQUEST, str(exc))
                return self._send_json(p.to_json(), HTTPStatus.CREATED)
            raise HTTPError(HTTPStatus.METHOD_NOT_ALLOWED)

        if path == "/api/playlists/sync":
            if method != "POST":
                raise HTTPError(HTTPStatus.METHOD_NOT_ALLOWED)
            body = self._read_json()
            incoming = body.get("playlists") if isinstance(body, dict) else None
            if not isinstance(incoming, list):
                raise HTTPError(HTTPStatus.BAD_REQUEST, "playlists array expected")
            try:
                merged = svc.playlists.merge(incoming)
            except PlaylistError as exc:
                raise HTTPError(HTTPStatus.BAD_REQUEST, str(exc))
            return self._send_json({"playlists": [p.to_json() for p in merged]})

        if m := PLAYLIST_RE.match(path):
            pid = m.group(1)
            if method == "GET":
                p = svc.playlists.get(pid)
                if not p:
                    raise HTTPError(HTTPStatus.NOT_FOUND, "playlist not found")
                return self._send_json(p.to_json())
            if method == "PUT":
                body = self._read_json()
                if not isinstance(body, dict):
                    raise HTTPError(HTTPStatus.BAD_REQUEST, "object expected")
                name = body.get("name")
                track_ids = body.get("trackIds")
                if name is not None and not isinstance(name, str):
                    raise HTTPError(HTTPStatus.BAD_REQUEST, "invalid name")
                if track_ids is not None and (
                    not isinstance(track_ids, list) or not all(isinstance(t, str) for t in track_ids)
                ):
                    raise HTTPError(HTTPStatus.BAD_REQUEST, "invalid trackIds")
                try:
                    p = svc.playlists.update(pid, name=name, track_ids=track_ids)
                except KeyError:
                    raise HTTPError(HTTPStatus.NOT_FOUND, "playlist not found")
                except PlaylistError as exc:
                    raise HTTPError(HTTPStatus.BAD_REQUEST, str(exc))
                return self._send_json(p.to_json())
            if method == "DELETE":
                if not svc.playlists.delete(pid):
                    raise HTTPError(HTTPStatus.NOT_FOUND, "playlist not found")
                return self._send_json({"ok": True})
            raise HTTPError(HTTPStatus.METHOD_NOT_ALLOWED)

        if path == "/api/rescan" and method == "POST":
            self._drain_body()
            result = svc.refresh(force=True)
            return self._send_json({
                "added": result.added, "updated": result.updated,
                "removed": result.removed, "unchanged": result.unchanged,
            })

        raise HTTPError(HTTPStatus.NOT_FOUND)

    # ------------------------------------------------------------ ファイル送信
    def _send_track(self, track_id: str) -> None:
        track = self.service.library.get(track_id)
        if not track:
            raise HTTPError(HTTPStatus.NOT_FOUND, "track not found")
        try:
            path = self.service.library.file_path(track)
        except PermissionError:
            raise HTTPError(HTTPStatus.FORBIDDEN)
        if not path.is_file():
            raise HTTPError(HTTPStatus.NOT_FOUND, "file missing")
        self._send_file(path, track.content_type, etag=track.sha256)

    def _send_file(self, path, content_type: str, etag: str | None = None,
                   cache: bool = False) -> None:
        try:
            f = open(path, "rb")
        except OSError:
            raise HTTPError(HTTPStatus.NOT_FOUND, "file missing")
        with f:
            size = os.fstat(f.fileno()).st_size
            start, end = 0, size - 1
            status = HTTPStatus.OK
            range_header = self.headers.get("Range")
            if range_header and size > 0:
                m = RANGE_RE.match(range_header.strip())
                if not m or (not m.group(1) and not m.group(2)):
                    return self._range_not_satisfiable(size)
                if m.group(1):
                    start = int(m.group(1))
                    end = int(m.group(2)) if m.group(2) else size - 1
                else:  # suffix range: bytes=-500
                    start = max(0, size - int(m.group(2)))
                end = min(end, size - 1)
                if start > end or start >= size:
                    return self._range_not_satisfiable(size)
                status = HTTPStatus.PARTIAL_CONTENT
            length = end - start + 1 if size else 0
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(length))
            self.send_header("Accept-Ranges", "bytes")
            if etag:
                self.send_header("ETag", f'"{etag}"')
            if cache:
                self.send_header("Cache-Control", "private, max-age=31536000, immutable")
            if status == HTTPStatus.PARTIAL_CONTENT:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            if self.command == "HEAD" or length == 0:
                return
            f.seek(start)
            remaining = length
            while remaining > 0:
                chunk = f.read(min(256 * 1024, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)

    def _range_not_satisfiable(self, size: int) -> None:
        self.send_response(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
        self.send_header("Content-Range", f"bytes */{size}")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _send_web_ui(self) -> None:
        body = resources.files("musicsync").joinpath("web/index.html").read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy",
                         "default-src 'self'; img-src 'self' data:; style-src 'unsafe-inline'; "
                         "script-src 'unsafe-inline'")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)


class MusicSyncHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def make_server(service: MusicSyncService, host: str = "0.0.0.0", port: int = 8765) -> MusicSyncHTTPServer:
    handler = type("BoundHandler", (Handler,), {"service": service})
    return MusicSyncHTTPServer((host, port), handler)


def lan_addresses() -> list[str]:
    """iPhone から接続できそうな LAN の IPv4 アドレス。"""
    addrs: list[str] = []
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("10.255.255.255", 1))  # 実際には送信しない
            addrs.append(s.getsockname()[0])
    except OSError:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if ip not in addrs and not ip.startswith("127."):
                addrs.append(ip)
    except OSError:
        pass
    return addrs or ["127.0.0.1"]
