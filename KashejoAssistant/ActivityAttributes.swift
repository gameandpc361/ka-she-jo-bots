import Foundation
import ActivityKit

struct KashejoQueueAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var completed: Int
        var total: Int
        var status: String
        var nextAt: Date?
    }

    var title: String
}
