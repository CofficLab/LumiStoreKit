import Foundation
import Testing
@testable import KitStoreKit

/// 订阅「增量合并」语义的测试。
///
/// ## 为什么这组测试最重要
///
/// `StoreKitService.applyTransaction` 曾用单笔交易构造 holding 并整体
/// **覆盖**当前状态，与 `calibrateFromCurrentEntitlements` 的**聚合**
/// 语义不一致，带来两个严重的付费权益错误：
///
/// 1. **期限被改写**：已买 `pro.year.1`（一年）后再买 `pro.monthly`，
///    权益从「一年」被改写成「一个月」——用户买了更长的档期反而被降级。
/// 2. **年付权益丢失**：同时持有 monthly + yearly 时，新交易会把 holding
///    整个替换成只含新商品的那一份，年付从集合里消失。
///
/// 这两条断言把「合并」语义锁死，防止回归。
@Suite("订阅增量合并语义")
struct StoreKitSubscriptionMergingTests {

    /// 基准时间。
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// 构造一笔自动续期交易。
    private func makeTransaction(
        productID: String,
        expiresIn: TimeInterval
    ) -> StoreKitTransactionSummary {
        StoreKitTransactionSummary(
            productID: productID,
            productType: .autoRenewable,
            expirationDate: now.addingTimeInterval(expiresIn),
            purchaseDate: now
        )
    }

    /// 已有一年期，再买月付：**期限不被改写**。
    ///
    /// 这是覆盖语义下最严重的 bug：用户买了更长的档期，权益反而变短。
    @Test
    func shorterTransactionDoesNotShortenExistingEntitlement() {
        let current = StoreKitSubscriptionHolding(
            activeSubscriptionProductIDs: ["pro.year.1"],
            latestExpiration: now.addingTimeInterval(365 * 24 * 60 * 60)
        )
        let transaction = makeTransaction(productID: "pro.monthly", expiresIn: 30 * 24 * 60 * 60)

        let merged = StoreKitSubscriptionAggregator.merging(
            current: current,
            transaction: transaction,
            now: now
        )

        // 到期时间仍是**最晚**的那个（一年）。
        #expect(merged.latestExpiration == now.addingTimeInterval(365 * 24 * 60 * 60))
    }

    /// 已有一年期，再买月付：**年付权益不丢失**。
    @Test
    func existingSubscriptionIsNotDropped() {
        let current = StoreKitSubscriptionHolding(
            activeSubscriptionProductIDs: ["pro.year.1"],
            latestExpiration: now.addingTimeInterval(365 * 24 * 60 * 60)
        )
        let transaction = makeTransaction(productID: "pro.monthly", expiresIn: 30 * 24 * 60 * 60)

        let merged = StoreKitSubscriptionAggregator.merging(
            current: current,
            transaction: transaction,
            now: now
        )

        #expect(merged.activeSubscriptionProductIDs.contains("pro.year.1"))
        #expect(merged.activeSubscriptionProductIDs.contains("pro.monthly"))
    }

    /// 合并后的集合与「全量聚合」的结论一致。
    ///
    /// 这是语义一致性的核心断言：合并（增量）与聚合（全量）
    /// 必须给出**同一个**答案，否则两条路径会产出不同的权益。
    @Test
    func mergingMatchesFullAggregation() {
        let year = makeTransaction(productID: "pro.year.1", expiresIn: 365 * 24 * 60 * 60)
        let month = makeTransaction(productID: "pro.monthly", expiresIn: 30 * 24 * 60 * 60)

        // 增量路径：先有一年期，再并入月付。
        let afterYear = StoreKitSubscriptionAggregator.merging(
            current: .none,
            transaction: year,
            now: now
        )
        let afterMonth = StoreKitSubscriptionAggregator.merging(
            current: afterYear,
            transaction: month,
            now: now
        )

        // 全量路径：一次性聚合两笔交易。
        let aggregated = StoreKitSubscriptionAggregator.aggregate(
            transactions: [year, month],
            now: now
        )

        #expect(Set(afterMonth.activeSubscriptionProductIDs)
            == Set(aggregated.activeSubscriptionProductIDs))
        #expect(afterMonth.latestExpiration == aggregated.latestExpiration)
    }

    /// 重复购买同一商品：商品 ID 不重复。
    @Test
    func duplicateProductIsNotAddedTwice() {
        let current = StoreKitSubscriptionHolding(
            activeSubscriptionProductIDs: ["pro.monthly"],
            latestExpiration: now.addingTimeInterval(30 * 24 * 60 * 60)
        )
        let transaction = makeTransaction(productID: "pro.monthly", expiresIn: 30 * 24 * 60 * 60)

        let merged = StoreKitSubscriptionAggregator.merging(
            current: current,
            transaction: transaction,
            now: now
        )

        #expect(merged.activeSubscriptionProductIDs == ["pro.monthly"])
    }

    /// 新的更长期限：延长既有权益。
    @Test
    func longerTransactionExtendsEntitlement() {
        let current = StoreKitSubscriptionHolding(
            activeSubscriptionProductIDs: ["pro.monthly"],
            latestExpiration: now.addingTimeInterval(30 * 24 * 60 * 60)
        )
        let transaction = makeTransaction(productID: "pro.year.1", expiresIn: 365 * 24 * 60 * 60)

        let merged = StoreKitSubscriptionAggregator.merging(
            current: current,
            transaction: transaction,
            now: now
        )

        #expect(merged.latestExpiration == now.addingTimeInterval(365 * 24 * 60 * 60))
    }

    /// 已过期的交易：**不改变**既有权益。
    ///
    /// 一笔无效交易不应抹掉用户已有的订阅。
    @Test
    func expiredTransactionDoesNotAffectEntitlement() {
        let current = StoreKitSubscriptionHolding(
            activeSubscriptionProductIDs: ["pro.year.1"],
            latestExpiration: now.addingTimeInterval(365 * 24 * 60 * 60)
        )
        let expired = makeTransaction(productID: "pro.trial", expiresIn: -24 * 60 * 60)

        let merged = StoreKitSubscriptionAggregator.merging(
            current: current,
            transaction: expired,
            now: now
        )

        #expect(merged == current)
    }

    /// 消耗品与非消耗品：**不授予**订阅权益，也不影响既有权益。
    @Test
    func nonSubscriptionTransactionIsIgnored() {
        let current = StoreKitSubscriptionHolding(
            activeSubscriptionProductIDs: ["pro.year.1"],
            latestExpiration: now.addingTimeInterval(365 * 24 * 60 * 60)
        )

        for productType in [StoreKitProductType.consumable, .nonConsumable] {
            let transaction = StoreKitTransactionSummary(
                productID: "com.example.nonSubscription",
                productType: productType,
                expirationDate: nil,
                purchaseDate: now
            )

            let merged = StoreKitSubscriptionAggregator.merging(
                current: current,
                transaction: transaction,
                now: now
            )

            #expect(merged == current)
        }
    }

    /// 空持有 + 首笔交易：等价于单笔聚合。
    @Test
    func firstTransactionOnEmptyHoldingMatchesAggregation() {
        let transaction = makeTransaction(productID: "pro.monthly", expiresIn: 30 * 24 * 60 * 60)

        let merged = StoreKitSubscriptionAggregator.merging(
            current: .none,
            transaction: transaction,
            now: now
        )
        let aggregated = StoreKitSubscriptionAggregator.aggregate(
            transactions: [transaction],
            now: now
        )

        #expect(merged.activeSubscriptionProductIDs == aggregated.activeSubscriptionProductIDs)
        #expect(merged.latestExpiration == aggregated.latestExpiration)
    }

    /// 非续订订阅缺失到期时间时，按静态回退时长推算。
    @Test
    func nonRenewableWithoutExpirationUsesFallback() {
        let transaction = StoreKitTransactionSummary(
            productID: "com.example.trial",
            productType: .nonRenewable,
            expirationDate: nil,
            purchaseDate: now
        )

        let merged = StoreKitSubscriptionAggregator.merging(
            current: .none,
            transaction: transaction,
            now: now
        )

        #expect(merged.latestExpiration == now.addingTimeInterval(
            StoreKitSubscriptionAggregator.nonRenewingFallbackDuration
        ))
    }
}
