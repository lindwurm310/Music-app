import os
import time

from conftest import make_audio, make_image, make_wav, needs_ffmpeg

from musicsync import artwork
from musicsync.library import Library, album_key, track_id_for, _parse_int


def test_parse_int():
    assert _parse_int("3/12") == 3
    assert _parse_int("2001-05-01") == 2001
    assert _parse_int("") == 0
    assert _parse_int(None) == 0
    assert _parse_int(["07"]) == 7


def test_track_id_is_unicode_normalized():
    import unicodedata
    name = "ポップス/ガ.mp3"
    assert track_id_for(unicodedata.normalize("NFD", name)) == track_id_for(name)


def test_album_key_normalizes_width_and_case():
    assert album_key("ＡＢＣ", " Best  Of ") == album_key("abc", "best of")


def test_scan_finds_only_audio_and_skips_hidden(music_dir):
    make_wav(music_dir / "a" / "one.wav")
    make_wav(music_dir / ".hidden" / "two.wav")
    (music_dir / "notes.txt").write_text("x")
    (music_dir / "video.mp4").write_bytes(b"x")
    lib = Library(music_dir)
    r = lib.scan()
    assert r.added == 1
    assert [t.path for t in lib.tracks()] == ["a/one.wav"]
    t = lib.tracks()[0]
    assert t.title == "one"  # タグが無ければファイル名
    assert len(t.sha256) == 64


def test_rescan_is_incremental(music_dir):
    p = make_wav(music_dir / "one.wav")
    lib = Library(music_dir)
    lib.scan()
    r = lib.scan()
    assert (r.added, r.updated, r.removed, r.unchanged) == (0, 0, 0, 1)
    # 内容を変更すると updated
    make_wav(p, seconds=0.5)
    os.utime(p, ns=(time.time_ns(), time.time_ns() + 10_000_000))
    r = lib.scan()
    assert r.updated == 1
    p.unlink()
    r = lib.scan()
    assert r.removed == 1 and lib.tracks() == []


def test_index_persists(music_dir):
    make_wav(music_dir / "one.wav")
    Library(music_dir).scan()
    lib2 = Library(music_dir)
    assert len(lib2.tracks()) == 1
    assert lib2.scan().unchanged == 1


def test_corrupt_index_recovers(music_dir):
    make_wav(music_dir / "one.wav")
    lib = Library(music_dir)
    lib.scan()
    lib.index_path.write_text("{not json")
    lib2 = Library(music_dir)
    assert lib2.scan().added == 1


@needs_ffmpeg
def test_metadata_and_sort(music_dir):
    make_audio(music_dir / "b.mp3", title="Second", artist="X", album="Alb", track=2)
    make_audio(music_dir / "a.m4a", title="First", artist="X", album="Alb", track=1)
    make_audio(music_dir / "c.flac", title="Third", artist="X", album="Alb", track=3)
    lib = Library(music_dir)
    lib.scan()
    assert [t.title for t in lib.tracks()] == ["First", "Second", "Third"]
    assert all(t.duration > 0 for t in lib.tracks())


@needs_ffmpeg
def test_folder_artwork_applied(music_dir):
    make_audio(music_dir / "Alb" / "1.mp3", album="Alb")
    (music_dir / "Alb" / "cover.png").write_bytes(make_image(fmt="PNG"))
    lib = Library(music_dir)
    lib.scan()
    t = lib.tracks()[0]
    assert t.artwork_id and t.folder_artwork_id == t.artwork_id
    data = lib.artwork_path(t.artwork_id).read_bytes()
    assert artwork.image_mime(data) == "image/jpeg"  # PNG→JPEG 正規化


@needs_ffmpeg
def test_embedded_art_shared_within_album(music_dir):
    a = make_audio(music_dir / "1.mp3", album="Alb", artist="X", track=1)
    make_audio(music_dir / "2.mp3", album="Alb", artist="X", track=2)
    assert artwork.embed_artwork(a, make_image())
    lib = Library(music_dir)
    lib.scan()
    t1, t2 = lib.tracks()
    assert t1.embedded_artwork_id and not t2.embedded_artwork_id
    assert t1.artwork_id == t2.artwork_id


def test_artwork_path_rejects_traversal(music_dir):
    lib = Library(music_dir)
    assert lib.artwork_path("../../etc/passwd") is None
    assert lib.artwork_path("") is None


def test_moved_file_detected_and_playlists_remapped(music_dir):
    from musicsync.service import MusicSyncService

    p = make_wav(music_dir / "Old" / "song.wav")
    svc = MusicSyncService(music_dir)
    svc.refresh(force=True)
    old_id = svc.library.tracks()[0].id
    pl = svc.playlists.create("x", [old_id, "other"])
    (music_dir / "New").mkdir()
    p.rename(music_dir / "New" / "song.wav")
    r = svc.refresh(force=True)
    new_id = svc.library.tracks()[0].id
    assert new_id != old_id and r.moved == {old_id: new_id}
    assert svc.playlists.get(pl.id).track_ids == [new_id, "other"]


@needs_ffmpeg
def test_folder_image_replaced_in_place(music_dir):
    make_audio(music_dir / "Alb" / "1.mp3", album="Alb")
    cover = music_dir / "Alb" / "cover.jpg"
    cover.write_bytes(make_image(color=(255, 0, 0)))
    lib = Library(music_dir)
    lib.scan()
    first = lib.tracks()[0].artwork_id
    cover.write_bytes(make_image(color=(0, 0, 255)))
    os.utime(cover, ns=(time.time_ns(), time.time_ns() + 10_000_000))
    lib.scan()
    assert lib.tracks()[0].artwork_id != first
