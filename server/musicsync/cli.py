"""コマンドライン: `musicsync serve ~/Music` など。"""

from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

from . import __version__
from .playlists import PlaylistError
from .service import MusicSyncService


def _service(args, **kw) -> MusicSyncService:
    return MusicSyncService(args.library, args.data_dir, **kw)


def _resolve_tracks(svc: MusicSyncService, queries: list[str]) -> list[str]:
    """トラック ID・相対パス・タイトル（部分一致）でトラックを指定できる。"""
    tracks = svc.library.tracks()
    ids: list[str] = []
    for q in queries:
        exact = [t for t in tracks if t.id == q or t.path == q]
        matches = exact or [t for t in tracks if q.casefold() in t.title.casefold()]
        if not matches:
            print(f"見つかりません: {q}", file=sys.stderr)
            continue
        if len(matches) > 1 and not exact:
            print(f"「{q}」に {len(matches)} 曲一致したため全て追加します", file=sys.stderr)
        ids.extend(t.id for t in matches)
    return ids


def cmd_serve(args) -> int:
    from .server import lan_addresses, make_server

    svc = _service(args, auto_artwork=not args.no_artwork, embed_artwork=args.embed_artwork)
    result = svc.refresh(force=True)
    server = make_server(svc, args.host, args.port)
    port = server.server_address[1]
    print(f"MusicSync {__version__}")
    print(f"  音楽フォルダ : {svc.library.root}")
    print(f"  曲数         : {len(svc.library.tracks())} 曲 (追加 {result.added} / 更新 {result.updated} / 削除 {result.removed})")
    print("  iPhone アプリの「サーバーを追加」に次を入力してください:")
    for ip in lan_addresses():
        print(f"    アドレス   : {ip}:{port}")
    print(f"    トークン   : {svc.token}")
    print(f"  PC でプレイリスト編集: http://localhost:{port}/")
    print("  終了するには Ctrl+C")
    sys.stdout.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n終了します")
    finally:
        server.server_close()
    return 0


def cmd_scan(args) -> int:
    svc = _service(args)
    r = svc.refresh(force=True)
    print(f"{len(svc.library.tracks())} 曲 (追加 {r.added} / 更新 {r.updated} / 削除 {r.removed} / エラー {r.errors})")
    missing = svc.library.albums_missing_artwork()
    if missing:
        print(f"アルバムアートが無いアルバム: {len(missing)} 件（`musicsync artwork` で自動取得できます）")
    return 0


def cmd_artwork(args) -> int:
    svc = _service(args)
    svc.refresh(force=True)
    report = svc.fill_artwork(embed=args.embed, force=args.force, online=not args.offline)
    print(f"検索 {report.albums_checked} 件 / 取得 {report.found} 件 / 見つからず {report.not_found} 件")
    if args.embed:
        print(f"ファイルへ埋め込み: {report.embedded_files} 曲")
    missing = svc.library.albums_missing_artwork()
    if missing and args.verbose:
        for tracks in missing.values():
            t = tracks[0]
            print(f"  未取得: {t.album_artist or t.artist} / {t.album}")
    return 0


def cmd_playlist(args) -> int:
    svc = _service(args)
    svc.refresh(force=True)
    store = svc.playlists
    tracks = {t.id: t for t in svc.library.tracks()}

    def need(name_or_id: str):
        p = store.find(name_or_id)
        if not p:
            print(f"プレイリストが見つかりません: {name_or_id}", file=sys.stderr)
            sys.exit(1)
        return p

    try:
        if args.action == "list":
            for p in store.all():
                print(f"{p.name}\t{len(p.track_ids)} 曲\t{p.id}")
        elif args.action == "show":
            p = need(args.playlist)
            for i, tid in enumerate(p.track_ids, 1):
                t = tracks.get(tid)
                print(f"{i:3}. {t.title} — {t.artist}" if t else f"{i:3}. (ライブラリに無い曲 {tid})")
        elif args.action == "create":
            p = store.create(args.name, _resolve_tracks(svc, args.tracks))
            print(f"作成しました: {p.name} ({len(p.track_ids)} 曲)")
        elif args.action == "add":
            p = store.add_tracks(need(args.playlist).id, _resolve_tracks(svc, args.tracks))
            print(f"{p.name}: {len(p.track_ids)} 曲")
        elif args.action == "remove":
            p = store.remove_tracks(need(args.playlist).id, _resolve_tracks(svc, args.tracks))
            print(f"{p.name}: {len(p.track_ids)} 曲")
        elif args.action == "rename":
            p = store.update(need(args.playlist).id, name=args.name)
            print(f"名前を変更しました: {p.name}")
        elif args.action == "delete":
            p = need(args.playlist)
            store.delete(p.id)
            print(f"削除しました: {p.name}")
        elif args.action == "export":
            p = need(args.playlist)
            lines = ["#EXTM3U"]
            for tid in p.track_ids:
                t = tracks.get(tid)
                if t:
                    lines.append(f"#EXTINF:{int(t.duration)},{t.artist} - {t.title}")
                    lines.append(t.path)
            out = Path(args.output) if args.output else svc.library.root / f"{p.name}.m3u8"
            out.write_text("\n".join(lines) + "\n", encoding="utf-8")
            print(f"書き出しました: {out}")
    except PlaylistError as exc:
        print(f"エラー: {exc}", file=sys.stderr)
        return 1
    return 0


def cmd_token(args) -> int:
    svc = _service(args)
    print(svc.reset_token() if args.reset else svc.token)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="musicsync", description="iPhone へ音楽だけをシンプルに同期")
    parser.add_argument("--version", action="version", version=__version__)
    parser.add_argument("-v", "--verbose", action="store_true")

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("library", help="音楽フォルダ")
    common.add_argument("--data-dir", help="設定・キャッシュの保存先（既定: <音楽フォルダ>/.musicsync）")

    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("serve", parents=[common], help="同期サーバーを起動")
    p.add_argument("--host", default="0.0.0.0")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--no-artwork", action="store_true", help="アルバムアートの自動取得をしない")
    p.add_argument("--embed-artwork", action="store_true", help="取得したアートを音楽ファイルに埋め込む")
    p.set_defaults(func=cmd_serve)

    p = sub.add_parser("scan", parents=[common], help="ライブラリをスキャン")
    p.set_defaults(func=cmd_scan)

    p = sub.add_parser("artwork", parents=[common], help="アルバムアートを自動取得")
    p.add_argument("--embed", action="store_true", help="音楽ファイルにも埋め込む")
    p.add_argument("--force", action="store_true", help="以前見つからなかったアルバムも再検索")
    p.add_argument("--offline", action="store_true", help="オンライン検索をしない（埋め込みのみ）")
    p.set_defaults(func=cmd_artwork)

    p = sub.add_parser("playlist", parents=[common], help="プレイリスト操作")
    psub = p.add_subparsers(dest="action", required=True)
    psub.add_parser("list")
    x = psub.add_parser("show"); x.add_argument("playlist")
    x = psub.add_parser("create"); x.add_argument("name"); x.add_argument("tracks", nargs="*")
    x = psub.add_parser("add"); x.add_argument("playlist"); x.add_argument("tracks", nargs="+")
    x = psub.add_parser("remove"); x.add_argument("playlist"); x.add_argument("tracks", nargs="+")
    x = psub.add_parser("rename"); x.add_argument("playlist"); x.add_argument("name")
    x = psub.add_parser("delete"); x.add_argument("playlist")
    x = psub.add_parser("export"); x.add_argument("playlist"); x.add_argument("-o", "--output")
    p.set_defaults(func=cmd_playlist)

    p = sub.add_parser("token", parents=[common], help="接続トークンを表示")
    p.add_argument("--reset", action="store_true", help="新しいトークンを発行")
    p.set_defaults(func=cmd_token)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s", datefmt="%H:%M:%S")
    try:
        return args.func(args)
    except FileNotFoundError as exc:
        print(f"エラー: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
