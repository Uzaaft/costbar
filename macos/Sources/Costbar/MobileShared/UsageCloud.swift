import CloudKit
import Foundation

actor UsageCloud {
    static let containerID = "iCloud.com.costbar.app"
    private let recordID = CKRecord.ID(recordName: "current-usage")
    private var database: CKDatabase { CKContainer(identifier: Self.containerID).privateCloudDatabase }

    func fetch() async throws -> UsageSnapshot? {
        do {
            let record = try await database.record(for: recordID)
            guard let data = record["payload"] as? Data else { throw CocoaError(.coderReadCorrupt) }
            return try UsageSnapshot.decode(data)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    func publish(_ snapshot: UsageSnapshot) async throws {
        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: "UsageSnapshot", recordID: recordID)
        }
        if let existing = record["payload"] as? Data,
           let current = try? UsageSnapshot.decode(existing),
           current.generatedAt > snapshot.generatedAt { return }
        record["payload"] = try JSONEncoder().encode(snapshot) as NSData
        _ = try await database.save(record)
    }

    func remove() async throws {
        do { _ = try await database.deleteRecord(withID: recordID) } catch let error as CKError where error.code == .unknownItem { return }
    }

    func subscribe() async throws {
        let subscription = CKQuerySubscription(
            recordType: "UsageSnapshot", predicate: NSPredicate(value: true),
            subscriptionID: "usage-updates", options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        _ = try await database.save(subscription)
    }
}
