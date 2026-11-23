#if canImport(UIKit) && !os(watchOS)
import AVFoundation
import SwiftUI
import UIKit

/// The banner's media and the app's icon (§2.4): fetched once from `cdn.scruter.net`, kept in `Library/Caches/ScruterCMP`
/// beside the configuration, decoded off the main thread. Every URL names its file by its SHA-256, so a file never
/// changes.
final class CMPMedia {
    static let shared = CMPMedia()

    private let queue = DispatchQueue(label: "net.scruter.cmp.media", qos: .utility)
    private let session: URLSession
    private let dir: URL
    private let memory = NSCache<NSString, UIImage>()
    private var waiting: [String: [(URL?) -> Void]] = [:]
    /// Images given by the tests (no network there).
    var fixtures: [String: UIImage] = [:]

    @_optimize(size) init() {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.timeoutIntervalForRequest = 20
        session = URLSession(configuration: c)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        dir = caches.appendingPathComponent("ScruterCMP", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    @_optimize(size) private func file(_ url: String) -> URL? {
        guard let u = URL(string: url), u.scheme == "https" || u.host == "127.0.0.1" || u.host == "localhost" else { return nil }
        let name = u.lastPathComponent.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
        return name.isEmpty ? nil : dir.appendingPathComponent(name)
    }

    /// The local file of `url`, downloaded once.
    @_optimize(size) func fetch(_ url: String, done: @escaping (URL?) -> Void) {
        queue.async {
            guard let f = self.file(url), let remote = URL(string: url) else { return done(nil) }
            if FileManager.default.fileExists(atPath: f.path) { return done(f) }
            if self.waiting[url] != nil {
                self.waiting[url]?.append(done)
                return
            }
            self.waiting[url] = [done]
            self.session.downloadTask(with: remote) { tmp, response, _ in
                var result: URL?
                if let tmp = tmp, let h = response as? HTTPURLResponse, h.statusCode == 200 {
                    try? FileManager.default.removeItem(at: f)
                    if (try? FileManager.default.moveItem(at: tmp, to: f)) != nil { result = f }
                }
                self.queue.async {
                    let callbacks = self.waiting.removeValue(forKey: url) ?? []
                    for cb in callbacks { cb(result) }
                }
            }.resume()
        }
    }

    @_optimize(size) func prefetch(_ urls: [String]) {
        for u in urls { fetch(u) { _ in } }
    }

    /// The image of `url`, decoded for display; `done` on the main thread.
    @_optimize(size) func image(_ url: String, done: @escaping (UIImage?) -> Void) {
        if let f = fixtures[url] { return done(f) }
        if let m = memory.object(forKey: url as NSString) { return done(m) }
        fetch(url) { f in
            let img = f.flatMap { UIImage(contentsOfFile: $0.path) }?.preparingForDisplay()
            if let i = img { self.memory.setObject(i, forKey: url as NSString) }
            DispatchQueue.main.async { done(img) }
        }
    }

    /// The image already in memory (snapshots, a second display).
    @_optimize(size) func cached(_ url: String) -> UIImage? { fixtures[url] ?? memory.object(forKey: url as NSString) }

    /// The poster file of the format nearest above `points` × the screen scale: WebP, else JPEG (decoded by every
    /// iOS 15 device; AVIF only from iOS 16).
    @_optimize(size) static func poster(_ hero: HeroUi, points: CGFloat, scale: CGFloat) -> String? {
        let need = Int(points * scale)
        for type in ["image/webp", "image/jpeg"] {
            let list = hero.poster.filter { $0.type == type }.sorted { $0.w < $1.w }
            if let s = list.first(where: { $0.w >= need }) ?? list.last { return s.url }
        }
        return hero.poster.first?.url
    }

    /// The H.264 MP4 of the loop (AV1 and VP9 are not decoded by every iPhone), nearest above the width.
    @_optimize(size) static func video(_ hero: HeroUi, points: CGFloat, scale: CGFloat) -> String? {
        let need = Int(points * scale)
        let list = (hero.video ?? []).filter { $0.type.hasPrefix("video/mp4") && ($0.type.contains("avc1") || !$0.type.contains("codecs")) }
            .sorted { $0.w < $1.w }
        return (list.first(where: { $0.w >= need }) ?? list.last)?.url
    }
}

/// An image from the media cache, with the tinted panel until it arrives.
struct CMPRemoteImage: View {
    let url: String?
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?

    @_optimize(size) var body: some View {
        ZStack {
            if let i = image ?? url.flatMap({ CMPMedia.shared.cached($0) }) {
                Image(uiImage: i).resizable().aspectRatio(contentMode: contentMode)
            }
        }
        .onAppear {
            guard image == nil, let u = url, CMPMedia.shared.cached(u) == nil else { return }
            CMPMedia.shared.image(u) { image = $0 }
        }
    }
}

/// The header's muted loop (§2.4): `AVPlayerLayer`, its poster first, started only after the sheet's first frame,
/// never under Reduce Motion or Low Power Mode (the poster stays and a play button starts it), a pause button
/// (WCAG 2.2.2), stopped and released when the sheet goes.
final class CMPLoopView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var statusObserver: NSKeyValueObservation?
    var onReady: () -> Void = {}

    @_optimize(size) func play(file: URL, gravity: AVLayerVideoGravity = .resizeAspectFill) {
        stop()
        let item = AVPlayerItem(url: file)
        let p = AVQueuePlayer()
        p.isMuted = true
        p.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: p, templateItem: item)
        let l = layer as! AVPlayerLayer
        l.videoGravity = gravity
        l.player = p
        player = p
        statusObserver = p.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            if p.timeControlStatus == .playing { DispatchQueue.main.async { self?.onReady() } }
        }
        p.play()
    }

    @_optimize(size) func pause() { player?.pause() }
    @_optimize(size) func resume() { player?.play() }

    @_optimize(size) func stop() {
        statusObserver = nil
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player?.removeAllItems()
        player = nil
        (layer as! AVPlayerLayer).player = nil
    }
}

struct CMPLoop: UIViewRepresentable {
    let file: URL
    let playing: Bool
    let onReady: () -> Void

    @_optimize(size) func makeUIView(context: Context) -> CMPLoopView {
        let v = CMPLoopView()
        v.isAccessibilityElement = false
        v.onReady = onReady
        v.play(file: file)
        return v
    }

    @_optimize(size) func updateUIView(_ v: CMPLoopView, context: Context) {
        if playing { v.resume() } else { v.pause() }
    }

    @_optimize(size) static func dismantleUIView(_ v: CMPLoopView, coordinator: ()) { v.stop() }
}
#endif
