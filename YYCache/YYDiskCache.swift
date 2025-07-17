//
//  YYDiskCache.swift
//  YYCache <https://github.com/ibireme/YYCache>
//
//  由 ibireme 创建于 2015/2/11。
//  本源码遵循 MIT 协议，详见根目录 LICENSE 文件。
//

import Foundation
import ObjectiveC

/// YYDiskCache：基于 KVStorage 的高性能磁盘缓存，线程安全，支持多种淘汰策略。
public class YYDiskCache {
    // MARK: - 属性
    public let path: String           // 缓存路径
    public let name: String?          // 缓存名称
    public let inlineThreshold: UInt  // 超过该字节数的对象将以文件存储，否则存入 sqlite
    public var errorLogsEnabled: Bool = true // 是否启用错误日志

    // 目录结构
    private let kv: YYKVStorage
    private let lock = DispatchSemaphore(value: 1)
    private let queue = DispatchQueue(label: "com.ibireme.cache.disk", qos: .utility)

    // MARK: - 初始化
    /// 初始化方法，传入缓存路径和 inlineThreshold
    public init?(path: String, inlineThreshold: UInt = 20480) {
        guard !path.isEmpty else {
            print("YYDiskCache 初始化错误：路径不能为空")
            return nil
        }
        self.path = path
        self.name = (path as NSString).lastPathComponent
        self.inlineThreshold = inlineThreshold
        // 选择存储类型
        let type: YYKVStorageType = (inlineThreshold == 0) ? .file : (inlineThreshold == UInt.max) ? .sqlite : .mixed
        guard let kv = YYKVStorage(path: path, type: type) else {
            print("YYDiskCache 初始化错误：KVStorage 创建失败")
            return nil
        }
        self.kv = kv
    }

    deinit {
        // 资源清理由 YYKVStorage 自动完成
    }

    // MARK: - 核心接口
    /// 判断缓存中是否存在指定 key
    public func containsObject(forKey key: String) -> Bool {
        lock.wait(); defer { lock.signal() }
        return kv.getItem(forKey: key) != nil
    }

    /// 获取指定 key 对应的对象
    public func object(forKey key: String) -> Data? {
        lock.wait(); defer { lock.signal() }
        return kv.getItem(forKey: key)?.value
    }

    /// 设置指定 key 的对象
    public func setObject(_ object: Data, forKey key: String) {
        lock.wait(); defer { lock.signal() }
        _ = kv.saveItem(key: key, value: object)
    }

    /// 移除指定 key 的对象
    public func removeObject(forKey key: String) {
        lock.wait(); defer { lock.signal() }
        _ = kv.removeItem(forKey: key)
    }

    /// 清空缓存
    public func removeAllObjects() {
        lock.wait(); defer { lock.signal() }
        _ = kv.removeAllItems()
    }

    /// 获取缓存对象总数
    public func totalCount() -> Int {
        lock.wait(); defer { lock.signal() }
        return kv.getItemsCount()
    }

    /// 获取缓存对象总 size
    public func totalSize() -> Int {
        lock.wait(); defer { lock.signal() }
        return kv.getItemsSize()
    }

    /// 按数量淘汰
    public func trimToCount(_ count: Int) {
        lock.wait(); defer { lock.signal() }
        _ = kv.removeItemsToFit(count: count)
    }

    /// 按 size 淘汰
    public func trimToSize(_ size: Int) {
        lock.wait(); defer { lock.signal() }
        _ = kv.removeItemsToFit(size: size)
    }

    /// 按时间淘汰（示例，实际应遍历所有对象的时间戳）
    public func trimToAge(_ age: Int) {
        let now = Int(Date().timeIntervalSince1970)
        let threshold = now - age
        lock.wait(); defer { lock.signal() }
        _ = kv.removeItems(earlierThan: threshold)
    }

    // MARK: - 扩展数据（完全等价实现）
    private static var extendedDataKey: UInt8 = 0

    /// 获取对象的扩展数据（等价于 OC 版 runtime 关联对象）
    public static func getExtendedData(from object: AnyObject) -> Data? {
        return objc_getAssociatedObject(object, &extendedDataKey) as? Data
    }

    /// 设置扩展数据到对象（等价于 OC 版 runtime 关联对象）
    public static func setExtendedData(_ extendedData: Data?, to object: AnyObject) {
        objc_setAssociatedObject(object, &extendedDataKey, extendedData, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
} 
