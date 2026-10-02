import Foundation

public struct KeyMapping: Codable, Equatable, Hashable, Sendable {
    public let source: UInt64
    public let destination: UInt64

    public init(source: UInt64, destination: UInt64) {
        self.source = source
        self.destination = destination
    }
}

public struct KeyboardDevice: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UInt64 { registryID }
    public let registryID: UInt64
    public let product: String
    public let vendorID: Int?
    public let productID: Int?
    public let locationID: Int?
    public let serialNumber: String?
    public let transport: String?
    public let isBuiltIn: Bool

    public init(registryID: UInt64, product: String, vendorID: Int? = nil,
                productID: Int? = nil, locationID: Int? = nil,
                serialNumber: String? = nil, transport: String? = nil,
                isBuiltIn: Bool) {
        self.registryID = registryID
        self.product = product
        self.vendorID = vendorID
        self.productID = productID
        self.locationID = locationID
        self.serialNumber = Self.nonempty(serialNumber)
        self.transport = Self.nonempty(transport)
        self.isBuiltIn = isBuiltIn
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}

/// Registry IDs identify a connection, so saved rules use hardware properties instead.
/// A serial number follows a device between ports. Without one, the location narrows a
/// vendor/product match to the selected connection. Product is only a display label.
public struct KeyboardFingerprint: Codable, Equatable, Hashable, Sendable {
    public let product: String
    public let vendorID: Int?
    public let productID: Int?
    public let locationID: Int?
    public let serialNumber: String?
    public let transport: String?

    public init(device: KeyboardDevice) {
        product = device.product
        vendorID = device.vendorID
        productID = device.productID
        locationID = device.serialNumber == nil ? device.locationID : nil
        serialNumber = device.serialNumber
        transport = device.transport
    }

    public var isValid: Bool {
        let hasSerial = serialNumber.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        let hasModel = vendorID != nil && productID != nil
        let numbersAreValid = [vendorID, productID, locationID].allSatisfy { $0.map { $0 >= 0 } ?? true }
        let stringsAreValid = [serialNumber, transport].allSatisfy {
            $0.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true
        }
        return (hasSerial || hasModel) && numbersAreValid && stringsAreValid
    }

    private enum CodingKeys: String, CodingKey {
        case product, vendorID, productID, locationID, serialNumber, transport
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        product = try container.decode(String.self, forKey: .product)
        vendorID = try container.decodeIfPresent(Int.self, forKey: .vendorID)
        productID = try container.decodeIfPresent(Int.self, forKey: .productID)
        locationID = try container.decodeIfPresent(Int.self, forKey: .locationID)
        serialNumber = try container.decodeIfPresent(String.self, forKey: .serialNumber)
        transport = try container.decodeIfPresent(String.self, forKey: .transport)
        guard isValid else {
            throw DecodingError.dataCorruptedError(forKey: .serialNumber, in: container,
                debugDescription: "A keyboard selector needs valid hardware identification.")
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.vendorID == rhs.vendorID && lhs.productID == rhs.productID
            && lhs.locationID == rhs.locationID && lhs.serialNumber == rhs.serialNumber
            && lhs.transport == rhs.transport
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(vendorID)
        hasher.combine(productID)
        hasher.combine(locationID)
        hasher.combine(serialNumber)
        hasher.combine(transport)
    }

    public func matches(device: KeyboardDevice) -> Bool {
        guard !device.isBuiltIn else { return false }
        // Refuse a product-only selector. Multiple devices can have the same marketing name.
        guard isValid else { return false }
        if let vendorID, vendorID != device.vendorID { return false }
        if let productID, productID != device.productID { return false }
        if let serialNumber, serialNumber != device.serialNumber { return false }
        if let locationID, locationID != device.locationID { return false }
        if let transport, transport != device.transport { return false }
        return true
    }
}

public enum KeyboardSelector: Codable, Equatable, Hashable, Sendable {
    case builtIn
    case external(KeyboardFingerprint)

    public init(device: KeyboardDevice) {
        self = device.isBuiltIn ? .builtIn : .external(KeyboardFingerprint(device: device))
    }

    public func matches(device: KeyboardDevice) -> Bool {
        switch self {
        case .builtIn: return device.isBuiltIn
        case .external(let fingerprint): return fingerprint.matches(device: device)
        }
    }

    public var displayName: String {
        switch self {
        case .builtIn: return "Built-in keyboard"
        case .external(let fingerprint): return fingerprint.product
        }
    }

    public var isValid: Bool {
        switch self {
        case .builtIn: return true
        case .external(let fingerprint): return fingerprint.isValid
        }
    }
}

public struct KeyboardRuleSet: Codable, Equatable, Sendable {
    public var selector: KeyboardSelector
    public var mappings: [KeyMapping]

    public init(selector: KeyboardSelector, mappings: [KeyMapping]) {
        self.selector = selector
        self.mappings = mappings
    }
}
