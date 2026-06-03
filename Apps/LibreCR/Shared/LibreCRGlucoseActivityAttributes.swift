import ActivityKit
import Foundation

struct LibreCRGlucoseActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let glucoseMgDL: Int
        let deltaMgDL: Int?
        let trend: UInt8
        let updatedAt: Date
    }

    let sensorName: String
}
