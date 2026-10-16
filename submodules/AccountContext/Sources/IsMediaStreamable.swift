import Foundation
import Postbox
import TelegramCore

private let minimalStreamableSize: Int = 384 * 1024

public func isMediaStreamable(message: Message, media: TelegramMediaFile) -> Bool {
    if message.containsSecretMedia {
        return false
    }
    if message.id.peerId.namespace == Namespaces.Peer.SecretChat {
        return false
    }
    guard let size = media.size else {
        return false
    }
    if size < minimalStreamableSize {
        return false
    }
    for attribute in media.attributes {
        if case let .Video(_, _, flags, _, _, _) = attribute {
            if flags.contains(.supportsStreaming) || !media.alternativeRepresentations.isEmpty {
                return true
            }
            break
        }
    }
    // OpenGram: .mkv играем встроенным проигрывателем (FFmpeg, демуксер
    // matroska в сборке есть) с потоковой загрузкой — в Telegram это было
    // включено только в DEBUG.
    if isMatroskaDocument(media) {
        return true
    }
    return false
}

/// Видеофайл .mkv, отправленный документом (без атрибута видео).
public func isMatroskaDocument(_ file: TelegramMediaFile) -> Bool {
    if file.mimeType == "video/x-matroska" {
        return true
    }
    if let fileName = file.fileName, fileName.lowercased().hasSuffix(".mkv") {
        return true
    }
    return false
}

public func isMediaStreamable(media: TelegramMediaFile) -> Bool {
    guard let size = media.size else {
        return false
    }
    if size < minimalStreamableSize {
        return false
    }
    for attribute in media.attributes {
        if case let .Video(_, _, flags, _, _, _) = attribute {
            if flags.contains(.supportsStreaming) {
                return true
            }
            break
        }
    }
    return false
}

public func isMediaStreamable(resource: MediaResource) -> Bool {
    if let size = resource.size, size >= minimalStreamableSize  {
        return true
    } else {
        return false
    }
}
