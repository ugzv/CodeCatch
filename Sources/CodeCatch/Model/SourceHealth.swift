import Foundation

enum SourceEvent: Equatable {
    case checked(Date)
    case message(Date)
    case retry(Date?)
}

struct SourceHealth: Equatable {
    var status: SourceStatus = .off
    var lastChecked: Date?
    var lastMessage: Date?
    var lastCode: Date?
    var retryAt: Date?

    mutating func record(_ event: SourceEvent) {
        switch event {
        case .checked(let date): lastChecked = max(lastChecked ?? date, date)
        case .message(let date): lastMessage = max(lastMessage ?? date, date)
        case .retry(let date): retryAt = date
        }
    }
}
