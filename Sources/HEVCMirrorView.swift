import SwiftUI
import AVFoundation
import VideoToolbox
import QuartzCore

/// Turns raw HEVC Annex-B access units (what `PcScreen.next_frame()` delivers) into
/// `CMSampleBuffer`s and feeds an `AVSampleBufferDisplayLayer`, which decodes +
/// draws them. Parameter sets (VPS/SPS/PPS) build the format description; VCL NALs
/// become display-immediately samples.
final class HEVCFeeder {
    let layer = AVSampleBufferDisplayLayer()
    var onFormat: ((Int, Int) -> Void)?
    /// Throttled (~1 Hz, main thread) playback stats: `(fps, pipelineLatencyMs)`.
    /// Latency is the PC-side cost — frame arrival off the core → enqueued for
    /// display — not glass-to-glass (the stream carries no phone timestamp).
    var onStats: ((Double, Double) -> Void)?

    private var vps: Data?
    private var sps: Data?
    private var pps: Data?
    private var format: CMVideoFormatDescription?

    // The layer decodes + displays on its own (VideoToolbox) threads; we feed it from
    // this dedicated serial queue so the 60 fps pipeline never runs on the main thread,
    // keeping the UI thread free for smooth animations. AVSampleBufferDisplayLayer is
    // designed to be enqueued from a background queue (only its geometry needs main).
    private let renderQueue = DispatchQueue(label: "tech.xvanturing.render", qos: .userInteractive)

    // Stats accumulation (touched only on `renderQueue`).
    private var statWindowStart = CACurrentMediaTime()
    private var statFrames = 0
    private var statLatencySum = 0.0

    init() {
        layer.videoGravity = .resizeAspect
    }

    /// Called on the frame-pump thread with one access unit.
    func handle(_ au: Data) {
        let received = CACurrentMediaTime()
        var vcl: [Data] = []
        for nal in Self.splitAnnexB(au) {
            guard let first = nal.first else { continue }
            let type = (first >> 1) & 0x3F // HEVC nal_unit_type
            switch type {
            case 32: vps = nal
            case 33: sps = nal
            case 34: pps = nal
            default: if type <= 31 { vcl.append(nal) } // VCL slice
            }
        }
        if format == nil { buildFormat() }
        guard let fmt = format, !vcl.isEmpty else { return }
        guard let sb = Self.makeSampleBuffer(vcl, fmt) else { return }
        // Feed off the main thread → the UI thread stays free, so chrome animations
        // don't hitch behind a 60 fps enqueue.
        renderQueue.async { [weak self] in
            guard let self else { return }
            if self.layer.status == .failed { self.layer.flush() }
            self.layer.enqueue(sb)
            self.recordStat(latencyMs: (CACurrentMediaTime() - received) * 1000)
        }
    }

    /// Accumulate one displayed frame and emit averaged stats about once a second.
    /// Runs on `renderQueue`; the stats callback is hopped to the main thread for the UI.
    private func recordStat(latencyMs: Double) {
        statFrames += 1
        statLatencySum += latencyMs
        let now = CACurrentMediaTime()
        let elapsed = now - statWindowStart
        if elapsed >= 1.0 {
            let fps = Double(statFrames) / elapsed
            let avgLatency = statFrames > 0 ? statLatencySum / Double(statFrames) : 0
            if let onStats { DispatchQueue.main.async { onStats(fps, avgLatency) } }
            statWindowStart = now
            statFrames = 0
            statLatencySum = 0
        }
    }

    private func buildFormat() {
        guard let vps, let sps, let pps else { return }
        var fmt: CMVideoFormatDescription?
        let status = vps.withUnsafeBytes { v in
            sps.withUnsafeBytes { s in
                pps.withUnsafeBytes { p in
                    let ptrs = [
                        v.bindMemory(to: UInt8.self).baseAddress!,
                        s.bindMemory(to: UInt8.self).baseAddress!,
                        p.bindMemory(to: UInt8.self).baseAddress!,
                    ]
                    let sizes = [vps.count, sps.count, pps.count]
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: ptrs,
                        parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &fmt)
                }
            }
        }
        if status == noErr, let fmt {
            format = fmt
            // Use the *presentation* (clean-aperture) size, not the coded size: when the
            // encoder pads to a block multiple, the coded width/height carries extra edge
            // pixels that would show as a black bar if we sized the window to them.
            let d = CMVideoFormatDescriptionGetPresentationDimensions(fmt, usePixelAspectRatio: true, useCleanAperture: true)
            onFormat?(Int(d.width.rounded()), Int(d.height.rounded()))
        } else {
            log("format description failed: \(status)")
        }
    }

    /// Split Annex-B (`00 00 01` / `00 00 00 01` start codes) into NAL payloads.
    static func splitAnnexB(_ data: Data) -> [Data] {
        let b = [UInt8](data)
        let n = b.count
        var starts: [(pos: Int, len: Int)] = []
        var i = 0
        while i + 2 < n {
            if b[i] == 0 && b[i + 1] == 0 {
                if b[i + 2] == 1 {
                    starts.append((i, 3)); i += 3; continue
                } else if i + 3 < n && b[i + 2] == 0 && b[i + 3] == 1 {
                    starts.append((i, 4)); i += 4; continue
                }
            }
            i += 1
        }
        var nals: [Data] = []
        for (idx, s) in starts.enumerated() {
            let begin = s.pos + s.len
            let end = idx + 1 < starts.count ? starts[idx + 1].pos : n
            if begin < end { nals.append(Data(b[begin..<end])) }
        }
        return nals
    }

    /// Length-prefix the VCL NALs (AVCC style) and wrap as a display-immediately sample.
    static func makeSampleBuffer(_ nals: [Data], _ fmt: CMVideoFormatDescription) -> CMSampleBuffer? {
        var avcc = Data()
        for nal in nals {
            var len = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }
        let total = avcc.count
        var bb: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: total,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: total, flags: 0, blockBufferOut: &bb) == noErr,
            let bb else { return nil }
        let copied = avcc.withUnsafeBytes { ptr -> Bool in
            CMBlockBufferReplaceDataBytes(
                with: ptr.baseAddress!, blockBuffer: bb,
                offsetIntoDestination: 0, dataLength: total) == noErr
        }
        guard copied else { return nil }

        var sb: CMSampleBuffer?
        var sampleSize = total
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: fmt,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sb) == noErr,
            let sb else { return nil }

        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
           CFArrayGetCount(atts) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }
}
