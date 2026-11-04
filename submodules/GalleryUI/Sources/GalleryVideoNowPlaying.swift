import Foundation
import UIKit
import MediaPlayer
import SwiftSignalKit
import AccountContext
import UniversalMediaPlayer

/// Экран блокировки и Пункт управления для видео из галереи: название,
/// позиция, «Пауза/Воспроизвести», ±15 с и перемотка ползунком. Раньше там
/// показывалась только музыка — незрячие тестировщики не могли управлять
/// видео, свернув приложение или заблокировав экран (отзыв 2026-11).
final class GalleryVideoNowPlaying {
    private static weak var current: GalleryVideoNowPlaying?

    private weak var videoNode: UniversalVideoNode?
    private let title: String
    private let artist: String?
    private let statusDisposable = MetaDisposable()
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var lastStatus: MediaPlayerStatus?
    private var isActive = false

    init(videoNode: UniversalVideoNode, title: String, artist: String?) {
        self.videoNode = videoNode
        self.title = title
        self.artist = artist
    }

    deinit {
        self.statusDisposable.dispose()
        self.deactivate()
    }

    func activate() {
        guard !self.isActive, let videoNode = self.videoNode else {
            return
        }
        if let current = GalleryVideoNowPlaying.current, current !== self {
            current.deactivate()
        }
        GalleryVideoNowPlaying.current = self
        self.isActive = true

        let commandCenter = MPRemoteCommandCenter.shared()

        func addTarget(_ command: MPRemoteCommand, _ handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            command.isEnabled = true
            let target = command.addTarget(handler: handler)
            self.commandTargets.append((command, target))
        }

        addTarget(commandCenter.playCommand, { [weak self] _ in
            self?.videoNode?.play()
            return .success
        })
        addTarget(commandCenter.pauseCommand, { [weak self] _ in
            self?.videoNode?.pause()
            return .success
        })
        addTarget(commandCenter.togglePlayPauseCommand, { [weak self] _ in
            self?.videoNode?.togglePlayPause()
            return .success
        })
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        addTarget(commandCenter.skipForwardCommand, { [weak self] _ in
            self?.seek(by: 15.0)
            return .success
        })
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        addTarget(commandCenter.skipBackwardCommand, { [weak self] _ in
            self?.seek(by: -15.0)
            return .success
        })
        addTarget(commandCenter.changePlaybackPositionCommand, { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self?.videoNode?.seek(event.positionTime)
            return .success
        })

        self.statusDisposable.set((videoNode.status
        |> deliverOnMainQueue).startStrict(next: { [weak self] status in
            self?.update(status: status)
        }))
    }

    func deactivate() {
        guard self.isActive else {
            return
        }
        self.isActive = false
        self.statusDisposable.set(nil)
        for (command, target) in self.commandTargets {
            command.removeTarget(target)
        }
        self.commandTargets.removeAll()
        if GalleryVideoNowPlaying.current === self {
            GalleryVideoNowPlaying.current = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }

    private func estimatedTimestamp() -> Double? {
        guard let status = self.lastStatus else {
            return nil
        }
        if case .playing = status.status {
            return status.timestamp + (CACurrentMediaTime() - status.generationTimestamp) * status.baseRate
        }
        return status.timestamp
    }

    private func seek(by delta: Double) {
        guard let timestamp = self.estimatedTimestamp() else {
            return
        }
        var target = max(0.0, timestamp + delta)
        if let duration = self.lastStatus?.duration, duration > 0.0 {
            target = min(duration, target)
        }
        self.videoNode?.seek(target)
    }

    private func update(status: MediaPlayerStatus?) {
        self.lastStatus = status
        guard self.isActive, GalleryVideoNowPlaying.current === self else {
            return
        }
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = self.title
        if let artist = self.artist {
            info[MPMediaItemPropertyArtist] = artist
        }
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        if let status {
            if status.duration > 0.0 {
                info[MPMediaItemPropertyPlaybackDuration] = status.duration as NSNumber
            }
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = (self.estimatedTimestamp() ?? status.timestamp) as NSNumber
            if case .playing = status.status {
                info[MPNowPlayingInfoPropertyPlaybackRate] = status.baseRate as NSNumber
            } else {
                info[MPNowPlayingInfoPropertyPlaybackRate] = 0.0 as NSNumber
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
