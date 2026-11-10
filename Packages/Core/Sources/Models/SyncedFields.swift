import Foundation

public struct SyncedFields: Codable, Equatable, Sendable {
    public struct Field: Codable, Equatable, Sendable {
        public var value: String
        public var updatedAt: Date

        public init(value: String, updatedAt: Date) {
            self.value = value
            self.updatedAt = updatedAt
        }
    }

    public static let unsynced = Date(timeIntervalSinceReferenceDate: 0)
    public static let saved = "saved"

    public var fields: [String: Field]

    public init(fields: [String: Field] = [:]) {
        self.fields = fields
    }

    public var marks: SyncedFields {
        SyncedFields(
            fields: fields.mapValues { Field(value: $0.value.isEmpty ? "" : Self.saved, updatedAt: $0.updatedAt) })
    }

    public func merged(with other: SyncedFields) -> SyncedFields {
        SyncedFields(
            fields: fields.merging(other.fields) { mine, theirs in
                if mine.updatedAt != theirs.updatedAt { return mine.updatedAt > theirs.updatedAt ? mine : theirs }
                return mine.value >= theirs.value ? mine : theirs
            })
    }

    public mutating func set(_ value: String, for key: String, at date: Date) {
        let earliest = fields[key].map { $0.updatedAt.addingTimeInterval(1) } ?? date
        fields[key] = Field(value: value, updatedAt: max(date, earliest))
    }

    public func recording(_ values: [String: String], at date: Date) -> SyncedFields {
        var result = self
        for (key, value) in values where value != (fields[key]?.value ?? "") {
            result.set(value, for: key, at: date)
        }
        return result
    }

    public static func secrets(_ stored: [String: String], marks: SyncedFields) -> SyncedFields {
        var result = SyncedFields()
        for (key, value) in stored {
            let mark = marks.fields[key]
            if !value.isEmpty {
                result.fields[key] = Field(value: value, updatedAt: mark?.updatedAt ?? unsynced)
            } else if let mark, mark.value.isEmpty {
                result.fields[key] = mark
            }
        }
        return result
    }
}
