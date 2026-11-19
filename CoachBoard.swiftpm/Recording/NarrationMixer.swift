import AVFoundation

/// 録画中に 1/30 秒ごとに記録する「その瞬間、動画のどこを何倍速で流していたか」
struct PlaybackSample {
    /// ホストクロック秒
    let wall: Double
    /// 動画内の時刻（秒）
    let video: Double
    let rate: Float
}

/// 連続して再生していた区間
struct PlaybackSegment {
    var wallStart: Double
    var wallEnd: Double
    var videoStart: Double
    var videoEnd: Double
    var rate: Float
}

enum PlaybackTimeline {
    /// 記録から「再生していた区間」を取り出す。停止・コマ送り・シークの間は音なしになる。
    static func segments(from samples: [PlaybackSample]) -> [PlaybackSegment] {
        var result: [PlaybackSegment] = []
        guard samples.count >= 2 else { return result }
        for i in 1..<samples.count {
            let a = samples[i - 1], b = samples[i]
            let dt = b.wall - a.wall
            let dv = b.video - a.video
            guard b.rate > 0, dt > 0, dv > 0 else { continue }
            // 速度に見合わない飛び（シーク）は除外
            let speed = dv / dt
            let expected = Double(b.rate)
            guard speed > expected * 0.3, speed < expected * 2 + 0.5 else { continue }

            if var last = result.last, last.wallEnd == a.wall, last.videoEnd == a.video, last.rate == b.rate {
                last.wallEnd = b.wall
                last.videoEnd = b.video
                result[result.count - 1] = last
            } else {
                result.append(PlaybackSegment(wallStart: a.wall, wallEnd: b.wall,
                                              videoStart: a.video, videoEnd: b.video, rate: b.rate))
            }
        }
        return result
    }
}

/// 書き出し時の音量設定（音声設定画面で変更できる）
struct NarrationMixSettings {
    enum Keys {
        static let gameVolume = "mix.gameVolume"
        static let micVolume = "mix.micVolume"
        static let ducking = "mix.ducking"
    }

    var gameVolume: Float
    var micVolume: Float
    var ducking: Bool

    static var current: NarrationMixSettings {
        let d = UserDefaults.standard
        return NarrationMixSettings(
            gameVolume: Float(d.object(forKey: Keys.gameVolume) as? Double ?? 0.8),
            micVolume: Float(d.object(forKey: Keys.micVolume) as? Double ?? 1.0),
            ducking: d.object(forKey: Keys.ducking) as? Bool ?? true
        )
    }
}

enum MixError: LocalizedError {
    case exportFailed
    var errorDescription: String? { "音声の書き出しに失敗しました。" }
}

/// 録画停止後に「映像」「その時鳴っていた動画の音」「マイクの声」を重ねて1本の mp4 にする
enum NarrationMixer {
    private static func t(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 48_000)
    }

    static func makeFinalMovie(videoOnly: URL,
                               source: URL?,
                               segments: [PlaybackSegment],
                               mic: MicRecorder.Result?,
                               wallOrigin: Double,
                               settings: NarrationMixSettings,
                               output: URL) async throws {
        let videoAsset = AVURLAsset(url: videoOnly)
        let totalDuration = try await videoAsset.load(.duration)
        let total = totalDuration.seconds

        let audioComposition = AVMutableComposition()
        var mixParameters: [AVMutableAudioMixInputParameters] = []

        let speech = mic.map { speechIntervals(levels: $0.levels, origin: wallOrigin, total: total) } ?? []

        // 1) 動画の音：再生していた区間だけを、録画上の同じ時刻に並べる（スロー再生は伸ばす）
        if let source, !segments.isEmpty {
            let sourceAsset = AVURLAsset(url: source)
            if let sourceTrack = try await sourceAsset.loadTracks(withMediaType: .audio).first,
               let track = audioComposition.addMutableTrack(withMediaType: .audio,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid) {
                let sourceDuration = try await sourceAsset.load(.duration).seconds
                var cursor = 0.0
                for segment in segments {
                    let wallStart = max(segment.wallStart - wallOrigin, cursor)
                    guard wallStart < total else { break }
                    let wallEnd = min(segment.wallEnd - wallOrigin, total)
                    let videoStart = max(0, segment.videoStart)
                    let videoEnd = min(segment.videoEnd, sourceDuration)
                    let wallLength = wallEnd - wallStart
                    let videoLength = videoEnd - videoStart
                    guard wallLength > 0.02, videoLength > 0.02 else { continue }

                    if wallStart > cursor + 0.001 {
                        track.insertEmptyTimeRange(CMTimeRange(start: t(cursor), duration: t(wallStart - cursor)))
                    }
                    try track.insertTimeRange(CMTimeRange(start: t(videoStart), duration: t(videoLength)),
                                              of: sourceTrack, at: t(wallStart))
                    if abs(videoLength - wallLength) > 0.001 {
                        track.scaleTimeRange(CMTimeRange(start: t(wallStart), duration: t(videoLength)),
                                             toDuration: t(wallLength))
                    }
                    cursor = wallStart + wallLength
                }
                if cursor > 0 {
                    let parameters = AVMutableAudioMixInputParameters(track: track)
                    applyGameVolume(parameters, base: settings.gameVolume,
                                    speech: settings.ducking ? speech : [])
                    mixParameters.append(parameters)
                } else {
                    audioComposition.removeTrack(track)
                }
            }
        }

        // 2) マイクの声：録音開始時刻に合わせて置く
        if let mic {
            let micAsset = AVURLAsset(url: mic.url)
            if let micTrack = try await micAsset.loadTracks(withMediaType: .audio).first,
               let track = audioComposition.addMutableTrack(withMediaType: .audio,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid) {
                let micDuration = try await micAsset.load(.duration).seconds
                let offset = mic.startHostSeconds - wallOrigin
                let sourceStart = offset < 0 ? -offset : 0
                let at = max(0, offset)
                let length = min(micDuration - sourceStart, total - at)
                if length > 0.05 {
                    if at > 0.001 {
                        track.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: t(at)))
                    }
                    try track.insertTimeRange(CMTimeRange(start: t(sourceStart), duration: t(length)),
                                              of: micTrack, at: t(at))
                    let parameters = AVMutableAudioMixInputParameters(track: track)
                    parameters.setVolume(settings.micVolume, at: .zero)
                    mixParameters.append(parameters)
                } else {
                    audioComposition.removeTrack(track)
                }
            }
        }

        // 音が何もなければ映像だけ保存
        guard !mixParameters.isEmpty else {
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.moveItem(at: videoOnly, to: output)
            return
        }

        // 3) 2つの音を混ぜて m4a に書き出す
        let mixedAudioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        defer { try? FileManager.default.removeItem(at: mixedAudioURL) }

        guard let audioExport = AVAssetExportSession(asset: audioComposition,
                                                     presetName: AVAssetExportPresetAppleM4A) else {
            throw MixError.exportFailed
        }
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = mixParameters
        audioExport.outputURL = mixedAudioURL
        audioExport.outputFileType = .m4a
        audioExport.audioMix = audioMix
        audioExport.audioTimePitchAlgorithm = .spectral // スロー再生でも音程を変えない
        try await run(audioExport)

        // 4) 映像と混ぜた音を1本にまとめる（映像は再圧縮しない）
        let final = AVMutableComposition()
        guard let videoSource = try await videoAsset.loadTracks(withMediaType: .video).first,
              let videoTrack = final.addMutableTrack(withMediaType: .video,
                                                     preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MixError.exportFailed
        }
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: totalDuration), of: videoSource, at: .zero)

        let mixedAsset = AVURLAsset(url: mixedAudioURL)
        if let audioSource = try await mixedAsset.loadTracks(withMediaType: .audio).first,
           let audioTrack = final.addMutableTrack(withMediaType: .audio,
                                                  preferredTrackID: kCMPersistentTrackID_Invalid) {
            let audioDuration = try await mixedAsset.load(.duration)
            try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(audioDuration, totalDuration)),
                                           of: audioSource, at: .zero)
        }

        guard let finalExport = AVAssetExportSession(asset: final, presetName: AVAssetExportPresetPassthrough) else {
            throw MixError.exportFailed
        }
        try? FileManager.default.removeItem(at: output)
        finalExport.outputURL = output
        finalExport.outputFileType = .mp4
        try await run(finalExport)
        try? FileManager.default.removeItem(at: videoOnly)
    }

    private static func run(_ session: AVAssetExportSession) async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                continuation.resume()
            }
        }
        guard session.status == .completed else {
            throw session.error ?? MixError.exportFailed
        }
    }

    // MARK: - 話している間だけゲーム音を下げる

    /// マイクの音量から「話している区間」（録画上の秒）を求める
    static func speechIntervals(levels: [MicRecorder.LevelSample], origin: Double, total: Double) -> [(Double, Double)] {
        let threshold: Float = -42   // これより大きい音を「話している」とみなす
        let mergeGap = 1.0           // 1秒未満の間は話し続けているとみなす
        let hold = 0.3               // 話し終わってから少し待ってから戻す
        var intervals: [(Double, Double)] = []
        for level in levels where level.db > threshold {
            let start = level.time - origin
            let end = start + 0.1
            if let last = intervals.last, start - last.1 < mergeGap {
                intervals[intervals.count - 1].1 = max(last.1, end)
            } else {
                intervals.append((start, end))
            }
        }
        return intervals
            .map { (max(0, $0.0), min(total, $0.1 + hold)) }
            .filter { $0.1 > $0.0 }
    }

    private static func applyGameVolume(_ parameters: AVMutableAudioMixInputParameters,
                                        base: Float, speech: [(Double, Double)]) {
        parameters.setVolume(base, at: .zero)
        let ducked = base * 0.4
        let fadeDown = 0.15
        let fadeUp = 0.4
        var previousEnd = 0.0
        for (start, end) in speech {
            let downStart = max(previousEnd, start - fadeDown)
            let downLength = max(0.01, start - downStart)
            parameters.setVolumeRamp(fromStartVolume: base, toEndVolume: ducked,
                                     timeRange: CMTimeRange(start: t(downStart), duration: t(downLength)))
            let upStart = max(end, downStart + downLength)
            parameters.setVolumeRamp(fromStartVolume: ducked, toEndVolume: base,
                                     timeRange: CMTimeRange(start: t(upStart), duration: t(fadeUp)))
            previousEnd = upStart + fadeUp
        }
    }
}
