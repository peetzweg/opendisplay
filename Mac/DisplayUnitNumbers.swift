import Foundation

enum DisplayUnitNumbers {
    static func hasDuplicates(_ unitNumbers: [UInt32]) -> Bool {
        Set(unitNumbers).count != unitNumbers.count
    }
}
