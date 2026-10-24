import XCTest
@testable import EditKit

// 拾光 · v1.0.x Hotfix H2 · EditKitTests/RenderNodeCacheTests.swift
// 编译目标：Linux 逻辑测试隔离包（真源 = ShiGuangKit/Sources/EditKit/RenderNodeCache.swift）

final class RenderNodeCacheTests: XCTestCase {

    func testFirstConsiderIsMiss() {
        var cache = RenderNodeCache<Int>(capacity: 4)
        XCTAssertEqual(cache.consider(1), .miss)
        XCTAssertFalse(cache.contains(2))
        XCTAssertTrue(cache.contains(1))
    }

    func testSameKeyHitsOnSecondConsider() {
        var cache = RenderNodeCache<Int>(capacity: 4)
        XCTAssertEqual(cache.consider(7), .miss)
        XCTAssertEqual(cache.consider(7), .hit)
        XCTAssertEqual(cache.missCount, 1)
        XCTAssertEqual(cache.hitCount, 1)
    }

    func testDistinctKeysStayMiss() {
        var cache = RenderNodeCache<Int>(capacity: 8)
        for k in 0..<8 { XCTAssertEqual(cache.consider(k), .miss) }
        XCTAssertEqual(cache.hitCount, 0)
        XCTAssertEqual(cache.count, 8)
    }

    func testLRUEvictionFreesOldest() {
        // 容量 3：装入 1/2/3 后，再装入 4 → 最久未用的 1 被淘汰；1 再次 consider 应为 miss
        var cache = RenderNodeCache<Int>(capacity: 3)
        for k in 1...3 { XCTAssertEqual(cache.consider(k), .miss) }
        XCTAssertEqual(cache.consider(4), .miss)
        XCTAssertEqual(cache.count, 3)
        XCTAssertFalse(cache.contains(1), "最久未用的键应被 LRU 淘汰")
        XCTAssertEqual(cache.consider(1), .miss, "淘汰后再次访问应为未命中")
        XCTAssertTrue(cache.contains(3), "最近使用的键应保留")
    }

    func testLRUHitMovesToRecent() {
        // 容量 2：1,2 → hit 1（1 移到最近）→ 装入 3 应淘汰 2（而非 1）
        var cache = RenderNodeCache<Int>(capacity: 2)
        XCTAssertEqual(cache.consider(1), .miss)
        XCTAssertEqual(cache.consider(2), .miss)
        XCTAssertEqual(cache.consider(1), .hit, "命中应将 1 移到最近")
        XCTAssertEqual(cache.consider(3), .miss)
        XCTAssertFalse(cache.contains(2), "2 是此时最久未用的，应被淘汰")
        XCTAssertTrue(cache.contains(1), "1 因刚命中而被保留")
    }

    func testCapacityEnforcedUnderChurn() {
        var cache = RenderNodeCache<Int>(capacity: 5)
        for k in 0..<20 { _ = cache.consider(k) }
        XCTAssertEqual(cache.count, 5, "任何时刻项数不超过容量")
    }

    func testHitRatio() {
        var cache = RenderNodeCache<Int>(capacity: 4)
        XCTAssertEqual(cache.hitRatio, 0)
        _ = cache.consider(1)          // miss
        _ = cache.consider(1)          // hit
        _ = cache.consider(1)          // hit
        XCTAssertEqual(cache.missCount, 1)
        XCTAssertEqual(cache.hitCount, 2)
        XCTAssertEqual(cache.hitRatio, 2.0 / 3.0, accuracy: 1e-9)
    }

    func testResetClearsState() {
        var cache = RenderNodeCache<Int>(capacity: 4)
        _ = cache.consider(1)
        _ = cache.consider(1)
        cache.reset()
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.hitCount, 0)
        XCTAssertEqual(cache.missCount, 0)
        XCTAssertEqual(cache.consider(1), .miss, "reset 后应为全新未命中")
    }

    func testHashableKeyType() {
        // 以字符串（图谱哈希的载体形式）为键，验证泛型可用性
        var cache = RenderNodeCache<String>(capacity: 2)
        XCTAssertEqual(cache.consider("graph-prefix-a"), .miss)
        XCTAssertEqual(cache.consider("graph-prefix-a"), .hit)
        XCTAssertEqual(cache.consider("graph-prefix-b"), .miss)
    }
}
