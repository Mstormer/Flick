import AppKit
import VideoToolbox

/// Small pictures for the timeline preview. Each is the keyframe at or before the asked-for frame, decoded
/// by its own VideoToolbox session straight to thumbnail size: one keyframe is a single decode (~15 ms for
/// 4K), where the exact frame could be hundreds. Recent pictures are kept; the session and the pictures
/// are dropped after a few idle seconds.
final class Thumbnailer {
    private let index: MediaIndex
    private let size: (w: Int, h: Int)
    private let q = DispatchQueue(label: "flick.thumbs", qos: .userInitiated)
    // all below on q
    private var session: VTDecompressionSession?
    private var cache: [Int: CGImage] = [:]
    private var order: [Int] = []                    // least recently used first
    private var wanted: (Int, (CGImage, Int) -> Void)?
    private var busy = false
    private var idle: DispatchWorkItem?
    /// Seconds to leave between decodes (while the main picture is being dragged, so the two decoders
    /// don't compete for the hardware).
    var spacing: Double = 0

    init(index: MediaIndex, width: Int = 384) {
        self.index = index
        let d = CMVideoFormatDescriptionGetDimensions(index.format)
        let w = min(width, Int(d.width))
        size = (w & ~1, (w * Int(d.height) / max(1, Int(d.width))) & ~1)
    }

    deinit { if let s = session { VTDecompressionSessionInvalidate(s) } }

    /// The picture for `frame`, on the main thread; only the latest request is decoded.
    func request(frame d: Int, _ done: @escaping (CGImage, Int) -> Void) {
        let k = index.gopStart(for: max(0, min(d, index.samples.count - 1)))
        let gap = spacing
        q.async { [self] in
            if let img = cache[k] {
                touch(k)
                DispatchQueue.main.async { done(img, k) }
                return
            }
            wanted = (k, done)
            if !busy { next(gap) }
        }
    }

    private func touch(_ k: Int) {
        if let i = order.firstIndex(of: k) { order.remove(at: i) }
        order.append(k)
    }

    private func next(_ gap: Double) {
        guard let (k, done) = wanted else { busy = false; scheduleIdle(); return }
        wanted = nil
        busy = true
        if let img = decode(k) {
            cache[k] = img
            touch(k)
            while order.count > 24 { cache[order.removeFirst()] = nil }   // ~8 MB at 384 px
            DispatchQueue.main.async { done(img, k) }
        }
        if gap > 0 { q.asyncAfter(deadline: .now() + gap) { [self] in next(spacing) } } else { next(0) }
    }

    private func decode(_ k: Int) -> CGImage? {
        if session == nil {
            let spec = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true] as CFDictionary
            let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                         kCVPixelBufferWidthKey: size.w, kCVPixelBufferHeightKey: size.h,
                         kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
            var s: VTDecompressionSession?
            VTDecompressionSessionCreate(allocator: nil, formatDescription: index.format, decoderSpecification: spec,
                                         imageBufferAttributes: attrs, outputCallback: nil, decompressionSessionOut: &s)
            session = s
        }
        guard let s = session, let sb = index.sampleBuffer(k) else { return nil }
        var out: CGImage?
        // synchronous: the handler runs before this returns
        let st = VTDecompressionSessionDecodeFrame(s, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            guard status == noErr, let image else { return }
            VTCreateCGImageFromCVPixelBuffer(image, options: nil, imageOut: &out)
        }
        if st != noErr { VTDecompressionSessionInvalidate(s); session = nil }
        return out
    }

    private func scheduleIdle() {
        idle?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.busy else { return }
            if let s = self.session { VTDecompressionSessionInvalidate(s) }
            self.session = nil
            self.cache = [:]; self.order = []
        }
        idle = w
        q.asyncAfter(deadline: .now() + 4, execute: w)
    }
}

/// The picture and time shown above the seek bar while hovering or dragging on it.
final class PreviewBubble: NSView {
    private let picture = CALayer()
    private let label = NSTextField(labelWithString: "0:00")
    private(set) var shownKey = -1
    var aspect: CGFloat = 16 / 9 { didSet { needsLayout = true } }
    static let width: CGFloat = 192

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.92).cgColor
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.25).cgColor
        layer?.masksToBounds = true
        picture.contentsGravity = .resizeAspectFill
        picture.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(picture)
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        addSubview(label)
        alphaValue = 0
        setAccessibilityElement(false)              // the seek bar already speaks the time
    }
    required init?(coder: NSCoder) { fatalError() }

    var height: CGFloat { (Self.width / aspect).rounded() + 22 }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        picture.frame = NSRect(x: 0, y: 22, width: bounds.width, height: bounds.height - 22)
        picture.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
        label.frame = NSRect(x: 0, y: 3, width: bounds.width, height: 16)
    }

    func setTime(_ text: String) { if label.stringValue != text { label.stringValue = text } }

    func setPicture(_ img: CGImage?, key: Int) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        picture.contents = img
        CATransaction.commit()
        shownKey = img == nil ? -1 : key
    }

    func show(_ on: Bool) {
        guard on != (alphaValue > 0) else { return }
        NSAnimationContext.runAnimationGroup { $0.duration = on ? 0.08 : 0.12; animator().alphaValue = on ? 1 : 0 }
    }
}
