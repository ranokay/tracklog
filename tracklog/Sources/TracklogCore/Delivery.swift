import Foundation

/// Where one listen's delivery to one connection stands.
public enum DeliveryState: String, CaseIterable, Equatable, Sendable {
    case waiting
    case retrying
    case delivered
    case abandoned

    /// Whether the delivery can still reach its connection.
    public var isPending: Bool {
        self == .waiting || self == .retrying
    }
}

/// One listen headed for one connection.
public struct Delivery: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let listenID: Int64
    public let connectionID: Int64
    public let state: DeliveryState
    /// Failed attempts so far. A manual retry never resets it.
    public let attempts: Int
    public let lastAttemptAt: Date?
    public let nextAttemptAt: Date?
    public let lastError: String?
    /// Why the row will never be delivered, when it is abandoned.
    public let abandonedReason: String?
    public let deliveredAt: Date?
    /// A service reference kept for a later operation, such as the
    /// ListenBrainz recording MSID a now playing returned.
    public let serviceReference: String?

    public init(
        id: Int64,
        listenID: Int64,
        connectionID: Int64,
        state: DeliveryState,
        attempts: Int,
        lastAttemptAt: Date? = nil,
        nextAttemptAt: Date? = nil,
        lastError: String? = nil,
        abandonedReason: String? = nil,
        deliveredAt: Date? = nil,
        serviceReference: String? = nil,
    ) {
        self.id = id
        self.listenID = listenID
        self.connectionID = connectionID
        self.state = state
        self.attempts = attempts
        self.lastAttemptAt = lastAttemptAt
        self.nextAttemptAt = nextAttemptAt
        self.lastError = lastError
        self.abandonedReason = abandonedReason
        self.deliveredAt = deliveredAt
        self.serviceReference = serviceReference
    }
}

public extension Delivery {
    /// Whether the last failed attempt backed off because the service was
    /// rate limiting. The stored text is written by ``DeliveryFailure`` and is
    /// never user input, so it can carry this meaning.
    var isRateLimited: Bool {
        state.isPending && lastError == DeliveryFailure.rateLimitedMessage
    }
}

/// A due delivery together with the listen it carries.
public struct QueuedDelivery: Equatable, Sendable {
    public let delivery: Delivery
    public let listen: Listen

    public init(delivery: Delivery, listen: Listen) {
        self.delivery = delivery
        self.listen = listen
    }
}

/// One item's outcome in a submitted batch. A rejection abandons only that
/// item; a thrown failure backs off the whole batch.
public enum DeliveryResult: Equatable, Sendable {
    case delivered(reference: String?)
    case rejected(reason: String?)
}

/// Durable deliveries. The SQLite store is the production implementation;
/// tests drive the real schema in a temporary container.
public protocol DeliveryStore: Sendable {
    /// Stores one listen and one waiting delivery per target in one
    /// transaction. Returns the stored listen, or `nil` when the durable
    /// duplicate key already exists; a duplicate writes no delivery rows.
    func insert(_ listen: Listen, targets: [Int64]) async throws -> Listen?

    /// The oldest due deliveries for one connection, oldest listen first.
    func dueDeliveries(
        for connectionID: Int64,
        limit: Int,
        at date: Date,
    ) async throws -> [QueuedDelivery]

    /// Every delivery carrying one listen, in connection order.
    func deliveries(for listenID: Int64) async throws -> [Delivery]

    /// Every delivery for the given listens, in listen then connection order.
    func deliveries(forListenIDs listenIDs: [Int64]) async throws -> [Delivery]

    /// Every pending delivery with its listen, oldest listen first. Future
    /// retries are included; the pending list is not only the due set.
    func pendingDeliveries() async throws -> [QueuedDelivery]

    func markDelivered(_ deliveryID: Int64, at date: Date, reference: String?) async throws

    /// Records one failed attempt and when the next one is due.
    func markFailed(
        _ deliveryID: Int64,
        attempts: Int,
        at date: Date,
        nextAttemptAt: Date,
        error: String,
    ) async throws

    /// Drops one delivery for good. The listen stays in local history.
    func abandon(
        _ deliveryID: Int64,
        attempts: Int,
        at date: Date,
        reason: String,
    ) async throws

    /// Makes every pending delivery for one connection due now, without
    /// touching attempts.
    func markDue(for connectionID: Int64, at date: Date) async throws

    /// The earliest next attempt among pending deliveries for these
    /// connections, or `nil` when none is pending.
    func earliestNextAttempt(for connectionIDs: [Int64]) async throws -> Date?
}
