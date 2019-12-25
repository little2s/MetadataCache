import XCTest
@testable import MetadataCache

struct TestAsset: Asset {
    let identifier: String
}

struct TestMetadata: Codable, Equatable, Metadata {
    let author: String
    let date: Date
}

final class TestLoadOperationProvider: MetadataLoadOperationProvider {

    typealias OP = DefaultMetadataLoadOperation<TestAsset, TestMetadata>
    
    static func makeOperation(asset: TestAsset?, options: MetadataLoaderOptions) -> DefaultMetadataLoadOperation<TestAsset, TestMetadata> {
        return .init(asset: asset, options: options, loadClosure: { _ in
            sleep(2)
            return (TestMetadata(author: UUID().uuidString, date: .init()), nil)
        })
    }
    
}

final class MetadataCacheTests: XCTestCase {
    func testExample() {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
        
        let manager = MetadataManager<TestLoadOperationProvider>.init(namespace: "tester")
        
        let assetA = TestAsset(identifier: "testerA")
        let assetB = TestAsset(identifier: "testerB")
        
        var metaA: TestMetadata?
        var metaB: TestMetadata?
        
        let group = DispatchGroup()
        
        group.enter()
        manager.loadMetadata(asset: assetA) { (meta, _, _, _, _) in
            metaA = meta
            group.leave()
        }
        
        group.enter()
        manager.loadMetadata(asset: assetB) { (meta, _, _, _, _) in
            metaB = meta
            group.leave()
        }
        
        var finished = false
        group.notify(queue: .main) {
            finished = true
        }
        
        while !finished {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        
        XCTAssert(metaA != metaB, "should not be equal")
    }

    static var allTests = [
        ("testExample", testExample),
    ]
}
