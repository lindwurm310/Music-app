import ImageIO
import MusicSyncCore
import SwiftUI
import UIKit

/// アルバムアートのメモリキャッシュ（NSCache はスレッドセーフ）
final class ArtworkCache: @unchecked Sendable {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSString, UIImage>()

    init() { cache.countLimit = 300 }

    /// - Parameter maxPixel: 指定するとサムネイルに縮小（一覧表示のメモリ節約）
    func image(for id: String, maxPixel: Int? = nil) -> UIImage? {
        let key = "\(id)@\(maxPixel ?? 0)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let url = Paths.artworkURL(for: id)
        let image: UIImage?
        if let maxPixel {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary).map { UIImage(cgImage: $0) }
        } else {
            image = UIImage(contentsOfFile: url.path)
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    func remove(_ id: String) {
        // サイズ違いのキーもあるので全体を消す（頻度は低い）
        cache.removeAllObjects()
    }

    func removeAll() { cache.removeAllObjects() }
}

struct ArtworkView: View {
    let artworkId: String?
    var size: CGFloat
    var cornerRadius: CGFloat = 6

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Color(.systemGray4), Color(.systemGray5)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.35))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
        .task(id: artworkId) {
            guard let artworkId else { image = nil; return }
            let pixel = Int(size * UIScreen.main.scale)
            let maxPixel: Int? = pixel >= 400 ? nil : pixel
            image = await Task.detached(priority: .utility) {
                ArtworkCache.shared.image(for: artworkId, maxPixel: maxPixel)
            }.value
        }
    }
}

/// 正方形でコンテナ幅いっぱいに広がるアート（グリッド・再生画面用）
struct FlexibleArtworkView: View {
    let artworkId: String?
    var cornerRadius: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ArtworkView(artworkId: artworkId, size: geo.size.width, cornerRadius: cornerRadius)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
