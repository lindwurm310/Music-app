from conftest import make_wav

from musicsync.cli import main


def test_cli_playlist_flow(music_dir, capsys):
    make_wav(music_dir / "Morning Song.wav")
    make_wav(music_dir / "Night Song.wav")
    lib = str(music_dir)
    assert main(["scan", lib]) == 0
    assert "2 曲" in capsys.readouterr().out
    assert main(["playlist", lib, "create", "朝", "Morning"]) == 0
    assert main(["playlist", lib, "add", "朝", "Night Song.wav"]) == 0
    capsys.readouterr()
    assert main(["playlist", lib, "show", "朝"]) == 0
    out = capsys.readouterr().out
    assert "Morning Song" in out and "Night Song" in out
    assert main(["playlist", lib, "remove", "朝", "Morning"]) == 0
    assert main(["playlist", lib, "rename", "朝", "夜"]) == 0
    assert main(["playlist", lib, "export", "夜"]) == 0
    m3u = (music_dir / "夜.m3u8").read_text(encoding="utf-8")
    assert m3u.startswith("#EXTM3U") and "Night Song.wav" in m3u
    capsys.readouterr()
    assert main(["playlist", lib, "list"]) == 0
    assert "夜\t1 曲" in capsys.readouterr().out
    assert main(["playlist", lib, "delete", "夜"]) == 0
    assert main(["playlist", lib, "create", " "]) == 1


def test_cli_token_and_missing_library(tmp_path, capsys):
    assert main(["token", str(tmp_path)]) == 0
    t1 = capsys.readouterr().out.strip()
    assert main(["token", str(tmp_path), "--reset"]) == 0
    assert capsys.readouterr().out.strip() != t1
    assert main(["scan", str(tmp_path / "nope")]) == 1


def test_cli_artwork_offline(music_dir, capsys):
    make_wav(music_dir / "x.wav")
    assert main(["artwork", str(music_dir), "--offline"]) == 0
    assert "検索 0 件" in capsys.readouterr().out
