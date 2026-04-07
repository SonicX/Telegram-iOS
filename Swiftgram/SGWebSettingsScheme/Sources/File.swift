import Foundation

public struct SGWebSettings: Codable, Equatable {
    public let global: SGGlobalSettings
    public let user: SGUserSettings
    
    public static var defaultValue: SGWebSettings {
        return SGWebSettings(global: SGGlobalSettings(ytPip: true, qrLogin: true, storiesAvailable: false, canViewMessages: true, canEditSettings: false, canShowTelescope: false, announcementsData: nil, regdateFormat: "month", botMonkeys: [], forceReasons: [], unforceReasons: [], paymentsEnabled: true, duckyAppIconAvailable: true, canGrant: false, proSupportUrl: nil, nyAvailable: false), user: SGUserSettings(contentReasons: [], canSendTelescope: false, canBuyInBeta: true))
    }
}

public struct SGGlobalSettings: Codable, Equatable {
    public let ytPip: Bool
    public let qrLogin: Bool
    public let storiesAvailable: Bool
    public let canViewMessages: Bool
    public let canEditSettings: Bool
    public let canShowTelescope: Bool
    public let announcementsData: String?
    public let regdateFormat: String
    public let botMonkeys: [SGBotMonkeys]
    public let forceReasons: [Int64]
    public let unforceReasons: [Int64]
    public let paymentsEnabled: Bool
    public let duckyAppIconAvailable: Bool
    public let canGrant: Bool
    public let proSupportUrl: String?
    public let nyAvailable: Bool

    enum CodingKeys: String, CodingKey {
        case ytPip
        case qrLogin
        case storiesAvailable
        case canViewMessages
        case canEditSettings
        case canShowTelescope
        case announcementsData
        case regdateFormat
        case botMonkeys
        case forceReasons
        case unforceReasons
        case paymentsEnabled
        case duckyAppIconAvailable
        case canGrant
        case proSupportUrl
        case nyAvailable
    }

    public init(
        ytPip: Bool,
        qrLogin: Bool,
        storiesAvailable: Bool,
        canViewMessages: Bool,
        canEditSettings: Bool,
        canShowTelescope: Bool,
        announcementsData: String?,
        regdateFormat: String,
        botMonkeys: [SGBotMonkeys],
        forceReasons: [Int64],
        unforceReasons: [Int64],
        paymentsEnabled: Bool,
        duckyAppIconAvailable: Bool,
        canGrant: Bool,
        proSupportUrl: String?,
        nyAvailable: Bool
    ) {
        self.ytPip = ytPip
        self.qrLogin = qrLogin
        self.storiesAvailable = storiesAvailable
        self.canViewMessages = canViewMessages
        self.canEditSettings = canEditSettings
        self.canShowTelescope = canShowTelescope
        self.announcementsData = announcementsData
        self.regdateFormat = regdateFormat
        self.botMonkeys = botMonkeys
        self.forceReasons = forceReasons
        self.unforceReasons = unforceReasons
        self.paymentsEnabled = paymentsEnabled
        self.duckyAppIconAvailable = duckyAppIconAvailable
        self.canGrant = canGrant
        self.proSupportUrl = proSupportUrl
        self.nyAvailable = nyAvailable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.ytPip = try container.decode(Bool.self, forKey: .ytPip)
        self.qrLogin = try container.decode(Bool.self, forKey: .qrLogin)
        self.storiesAvailable = try container.decode(Bool.self, forKey: .storiesAvailable)
        self.canViewMessages = try container.decode(Bool.self, forKey: .canViewMessages)
        self.canEditSettings = try container.decode(Bool.self, forKey: .canEditSettings)
        self.canShowTelescope = try container.decode(Bool.self, forKey: .canShowTelescope)
        self.announcementsData = try container.decodeIfPresent(String.self, forKey: .announcementsData)
        self.regdateFormat = try container.decode(String.self, forKey: .regdateFormat)
        self.botMonkeys = try container.decodeIfPresent([SGBotMonkeys].self, forKey: .botMonkeys) ?? []
        self.forceReasons = try container.decode([Int64].self, forKey: .forceReasons)
        self.unforceReasons = try container.decode([Int64].self, forKey: .unforceReasons)
        self.paymentsEnabled = try container.decode(Bool.self, forKey: .paymentsEnabled)
        self.duckyAppIconAvailable = try container.decode(Bool.self, forKey: .duckyAppIconAvailable)
        self.canGrant = try container.decode(Bool.self, forKey: .canGrant)
        self.proSupportUrl = try container.decodeIfPresent(String.self, forKey: .proSupportUrl)
        self.nyAvailable = try container.decode(Bool.self, forKey: .nyAvailable)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.ytPip, forKey: .ytPip)
        try container.encode(self.qrLogin, forKey: .qrLogin)
        try container.encode(self.storiesAvailable, forKey: .storiesAvailable)
        try container.encode(self.canViewMessages, forKey: .canViewMessages)
        try container.encode(self.canEditSettings, forKey: .canEditSettings)
        try container.encode(self.canShowTelescope, forKey: .canShowTelescope)
        try container.encodeIfPresent(self.announcementsData, forKey: .announcementsData)
        try container.encode(self.regdateFormat, forKey: .regdateFormat)
        try container.encode(self.botMonkeys, forKey: .botMonkeys)
        try container.encode(self.forceReasons, forKey: .forceReasons)
        try container.encode(self.unforceReasons, forKey: .unforceReasons)
        try container.encode(self.paymentsEnabled, forKey: .paymentsEnabled)
        try container.encode(self.duckyAppIconAvailable, forKey: .duckyAppIconAvailable)
        try container.encode(self.canGrant, forKey: .canGrant)
        try container.encodeIfPresent(self.proSupportUrl, forKey: .proSupportUrl)
        try container.encode(self.nyAvailable, forKey: .nyAvailable)
    }
}

public struct SGBotMonkeys: Codable, Equatable {
    public let botId: Int64
    public let src: String
    public let enable: String
    public let disable: String
}


public struct SGUserSettings: Codable, Equatable {
    public let contentReasons: [String]
    public let canSendTelescope: Bool
    public let canBuyInBeta: Bool
}


public extension SGUserSettings {
    func expandedContentReasons() -> [String] {
        return contentReasons.compactMap { base64String in
            guard let data = Data(base64Encoded: base64String),
                  let decodedString = String(data: data, encoding: .utf8) else {
                return nil
            }
            return decodedString
        }
    }
}
