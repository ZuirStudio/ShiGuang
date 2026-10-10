import Testing
import CoreGraphics
@testable import EditKit

/// R007b-1 Stage A：手势轴向锁定与段落化位移的内核测试。
@Suite struct ScrubTrackerTests {

    // MARK: - 轴向锁定

    @Test func locksVerticalWhenVerticalDominant() {
        var tracker = ScrubTracker()
        let update = tracker.update(translation: CGSize(width: 2, height: 20))
        #expect(update.axis == .vertical)
        #expect(update.axisChanged)
        #expect(tracker.axis == .vertical)
    }

    @Test func locksHorizontalWhenHorizontalDominant() {
        var tracker = ScrubTracker()
        let update = tracker.update(translation: CGSize(width: -30, height: 4))
        #expect(update.axis == .horizontal)
        #expect(tracker.axis == .horizontal)
    }

    @Test func doesNotLockBelowThreshold() {
        var tracker = ScrubTracker()
        let update = tracker.update(translation: CGSize(width: 3, height: 4))
        #expect(update.axis == nil)
        #expect(tracker.axis == nil)
        #expect(!update.axisChanged)
        #expect(update.verticalSteps == 0)
        #expect(update.horizontalProgress == 0)
    }

    /// 30° 斜角必须能判出一个轴向（而不是两个都不动）。
    @Test func locksOnObliqueAngle() {
        var tracker = ScrubTracker()
        let update = tracker.update(translation: CGSize(width: 10, height: 17.32))
        #expect(update.axis == .vertical)

        var other = ScrubTracker()
        let horizontal = other.update(translation: CGSize(width: 17.32, height: 10))
        #expect(horizontal.axis == .horizontal)
    }

    // MARK: - 轴向不抖动 / 明显逆转才换轴

    @Test func keepsLockedAxisOnSmallDeviation() {
        var tracker = ScrubTracker()
        _ = tracker.update(translation: CGSize(width: 2, height: 30))
        // 轻微横向偏移（不足 2 倍）不得换轴
        let update = tracker.update(translation: CGSize(width: 20, height: 40))
        #expect(update.axis == .vertical)
        #expect(!update.axisChanged)
    }

    @Test func switchesAxisOnlyOnObviousReversal() {
        var tracker = ScrubTracker()
        _ = tracker.update(translation: CGSize(width: 2, height: 30))
        // 横向位移 100 > 纵向 40 × 2 = 80 → 判为明显逆转
        let update = tracker.update(translation: CGSize(width: 100, height: 40))
        #expect(update.axis == .horizontal)
        #expect(update.axisChanged)
    }

    @Test func resetClearsAxis() {
        var tracker = ScrubTracker()
        _ = tracker.update(translation: CGSize(width: 0, height: 40))
        #expect(tracker.axis == .vertical)
        tracker.reset()
        #expect(tracker.axis == nil)
    }

    // MARK: - 段落化

    @Test func stepHeightIsFortyEightPoints() {
        var tracker = ScrubTracker()
        _ = tracker.update(translation: CGSize(width: 0, height: 0))
        // 先锁定
        _ = tracker.update(translation: CGSize(width: 1, height: 10))
        // 向上滑 96pt = 前两项
        #expect(tracker.verticalSteps(translation: CGSize(width: 1, height: -96)) == 2)
        // 向下滑 48pt = 后一项
        #expect(tracker.verticalSteps(translation: CGSize(width: 1, height: 48)) == -1)
        // 不足一格 = 0（不连续滚动）
        #expect(tracker.verticalSteps(translation: CGSize(width: 1, height: 40)) == 0)
    }

    @Test func stepsAreZeroWhileAxisIsHorizontal() {
        var tracker = ScrubTracker()
        _ = tracker.update(translation: CGSize(width: 40, height: 1))
        #expect(tracker.axis == .horizontal)
        #expect(tracker.verticalSteps(translation: CGSize(width: 40, height: -200)) == 0)
        #expect(tracker.horizontalProgress(translation: CGSize(width: 120, height: 0)) == 0.5)
    }

    @Test func stepsAreZeroBeforeLock() {
        let tracker = ScrubTracker()
        #expect(tracker.verticalSteps(translation: CGSize(width: 0, height: -200)) == 0)
        #expect(tracker.horizontalProgress(translation: CGSize(width: 200, height: 0)) == 0)
    }

    /// 长时间大幅度拖动不会「越界冲刺」：段落数按位移绝对映射，回拉即回退。
    @Test func largeDragMapsMonotonically() {
        var tracker = ScrubTracker()
        _ = tracker.update(translation: CGSize(width: 0, height: 10))
        let far = tracker.verticalSteps(translation: CGSize(width: 0, height: -960))
        #expect(far == 20)
        let back = tracker.verticalSteps(translation: CGSize(width: 0, height: -96))
        #expect(back == 2)
    }

    // MARK: - 索引 / 数值映射

    @Test func mappedIndexClampsAndReportsBoundary() {
        let top = ScrubTracker.mappedIndex(initial: 1, steps: 5, count: 8)
        #expect(top.index == 0)
        #expect(top.hitBoundary)

        let bottom = ScrubTracker.mappedIndex(initial: 6, steps: -5, count: 8)
        #expect(bottom.index == 7)
        #expect(bottom.hitBoundary)

        let middle = ScrubTracker.mappedIndex(initial: 3, steps: 1, count: 8)
        #expect(middle.index == 2)
        #expect(!middle.hitBoundary)
    }

    @Test func mappedIndexHandlesEmptyCount() {
        let empty = ScrubTracker.mappedIndex(initial: 0, steps: 0, count: 0)
        #expect(empty.index == 0)
        #expect(empty.hitBoundary)
    }

    @Test func mappedValueSpansRangeOverFullDrag() {
        let range = -100.0...100.0
        // 跨满 240pt = 走完整个跨度（sensitivity 1.0）
        let up = ScrubTracker.mappedValue(initial: 0, progress: 1.0, range: range)
        #expect(up.value == 100)
        #expect(up.hitBoundary)
        let down = ScrubTracker.mappedValue(initial: 0, progress: -1.0, range: range)
        #expect(down.value == -100)
    }

    @Test func mappedValueClampsInsideRange() {
        let range = 0.0...1.0
        let over = ScrubTracker.mappedValue(initial: 0.5, progress: 0.5, range: range)
        #expect(over.value == 1.0)
        #expect(over.hitBoundary)
        let inside = ScrubTracker.mappedValue(initial: 0.5, progress: 0.1, range: range)
        #expect(abs(inside.value - 0.6) < 1e-9)
        #expect(!inside.hitBoundary)
    }

    @Test func configurationClampsDegenerateValues() {
        let config = ScrubTracker.Configuration(lockThreshold: 0, stepHeight: 0, axisSwitchRatio: 0.1, fullRangeDistance: 0)
        #expect(config.lockThreshold > 0)
        #expect(config.stepHeight > 0)
        #expect(config.axisSwitchRatio >= 1)
        #expect(config.fullRangeDistance > 0)
    }

    @Test func defaultConfigurationMatchesSpec() {
        let config = ScrubTracker.Configuration.default
        #expect(config.lockThreshold == 8)
        #expect(config.stepHeight == 48)
        #expect(config.axisSwitchRatio == 2)
        #expect(config.fullRangeDistance == 240)
    }
}
