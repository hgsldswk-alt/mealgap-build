import ActivityKit
import Foundation

struct MealActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable { var start: Date; var zone: String }
    var intervalID: UUID
}
