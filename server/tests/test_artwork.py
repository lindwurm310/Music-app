import json

import pytest
from conftest import make_audio, make_image, needs_ffmpeg

from musicsync import artwork


def fake_http(routes):
    calls = []

    def get(url):
        calls.append(url)
        for prefix, body in routes.items():
            if url.startswith(prefix):
                return body(url) if callable(body) else body
        return None

    get.calls = calls
    return get


ITUNES = {
    "results": [
        {"collectionName": "Other Album", "artistName": "Someone", "artworkUrl100": "https://img/x/100x100bb.jpg"},
        {"collectionName": "First Love (Remastered)", "artistName": "宇多田ヒカル",
         "artworkUrl100": "https://img/fl/100x100bb.jpg"},
    ]
}


def test_similar_ignores_brackets_and_width():
    assert artwork._similar("First Love (Remastered)", "first love")
    assert artwork._similar("ＡＢＣ【Deluxe】", "abc")
    assert not artwork._similar("Abbey Road", "Let It Be")
    assert not artwork._similar("", "x")


def test_itunes_picks_matching_album_and_large_size():
    img = make_image()
    http = fake_http({"https://itunes.apple.com/": json.dumps(ITUNES).encode(),
                      "https://img/fl/600x600bb.jpg": img})
    assert artwork.search_itunes("宇多田ヒカル", "First Love", http) == img
    assert "https://img/fl/600x600bb.jpg" in http.calls
    assert not any("/x/" in c for c in http.calls)


def test_itunes_rejects_wrong_artist():
    http = fake_http({"https://itunes.apple.com/": json.dumps(ITUNES).encode(),
                      "https://img/": make_image()})
    assert artwork.search_itunes("Different Artist", "First Love", http) is None


def test_itunes_bad_json_and_non_image():
    assert artwork.search_itunes("a", "b", fake_http({"https://itunes.apple.com/": b"<html>"})) is None
    http = fake_http({"https://itunes.apple.com/": json.dumps(ITUNES).encode(), "https://img/": b"not image"})
    assert artwork.search_itunes("宇多田ヒカル", "First Love", http) is None


def test_musicbrainz_fallback():
    img = make_image()
    mb = {"releases": [{"id": "abc-123", "title": "Kid A"}]}
    http = fake_http({
        "https://itunes.apple.com/": json.dumps({"results": []}).encode(),
        "https://musicbrainz.org/": json.dumps(mb).encode(),
        "https://coverartarchive.org/release/abc-123/": img,
    })
    f = artwork.ArtworkFetcher.__new__(artwork.ArtworkFetcher)
    f.http_get, f.sources, f.misses = http, ("itunes", "musicbrainz"), {}
    f.cache_path = None
    f._save = lambda: None
    assert f.fetch("k", "Radiohead", "Kid A") == img


def test_negative_cache(tmp_path):
    http = fake_http({})
    f = artwork.ArtworkFetcher(tmp_path / "miss.json", http_get=http)
    assert f.fetch("k", "a", "b") is None
    n = len(http.calls)
    assert f.fetch("k", "a", "b") is None
    assert len(http.calls) == n  # 再検索しない
    f2 = artwork.ArtworkFetcher(tmp_path / "miss.json", http_get=http)
    assert f2.fetch("k", "a", "b") is None and len(http.calls) == n  # 永続化されている
    f2.fetch("k", "a", "b", force=True)
    assert len(http.calls) > n


def test_no_album_no_query(tmp_path):
    http = fake_http({})
    f = artwork.ArtworkFetcher(tmp_path / "m.json", http_get=http)
    assert f.fetch("k", "artist", "") is None
    assert http.calls == []


def test_normalize_image_resizes_and_handles_alpha():
    from PIL import Image
    import io

    buf = io.BytesIO()
    Image.new("RGBA", (1200, 900), (0, 0, 0, 0)).save(buf, format="PNG")
    out = artwork.normalize_image(buf.getvalue())
    img = Image.open(io.BytesIO(out))
    assert img.format == "JPEG" and max(img.size) == 600
    assert artwork.normalize_image(b"garbage") is None
    assert artwork.normalize_image(None) is None


def test_find_folder_image(tmp_path):
    (tmp_path / "back.jpg").write_bytes(b"x")
    (tmp_path / "Folder.JPG").write_bytes(b"x")
    assert artwork.find_folder_image(tmp_path).name == "Folder.JPG"
    other = tmp_path / "o"
    other.mkdir()
    (other / "scan1.png").write_bytes(b"x")
    assert artwork.find_folder_image(other).name == "scan1.png"
    (other / "scan2.png").write_bytes(b"x")
    assert artwork.find_folder_image(other) is None


@needs_ffmpeg
@pytest.mark.parametrize("ext", [".mp3", ".m4a", ".flac"])
def test_embed_roundtrip(tmp_path, ext):
    from conftest import make_wav

    p = make_audio(tmp_path / f"t{ext}")
    img = make_image()
    assert artwork.extract_embedded(p) is None
    assert artwork.embed_artwork(p, img)
    assert artwork.extract_embedded(p) == img
    # 再埋め込みで置き換わる（重複しない）
    img2 = make_image(color=(1, 2, 3))
    assert artwork.embed_artwork(p, img2)
    assert artwork.extract_embedded(p) == img2


def test_embed_wav_roundtrip(tmp_path):
    from conftest import make_wav

    p = make_wav(tmp_path / "t.wav")
    img = make_image()
    assert artwork.embed_artwork(p, img)
    assert artwork.extract_embedded(p) == img
