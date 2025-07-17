//
//  YYCache.swift
//  YYCache <https://github.com/ibireme/YYCache>
//
//  由 ibireme 创建于 2015/2/13。
//  本源码遵循 MIT 协议，详见根目录 LICENSE 文件。
//

import Foundation

/// YYCache：高性能多级缓存，组合内存缓存和磁盘缓存，线程安全。
public class YYCache {
    // MARK: - 属性
    public let name: String           // 缓存名称
    public let memoryCache: YYMemoryCache // 内存缓存
    public let diskCache: YYDiskCache     // 磁盘缓存

    // MARK: - 初始化
    /// 通过名称初始化（自动拼接缓存目录）
    public init?(name: String) {
        guard !name.isEmpty else { return nil }
        let cacheFolder = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()
        let path = (cacheFolder as NSString).appendingPathComponent(name)
        guard let disk = YYDiskCache(path: path) else { return nil }
        let memory = YYMemoryCache(name: name)
        self.name = name
        self.diskCache = disk
        self.memoryCache = memory
    }

    /// 通过路径初始化
    public init?(path: String) {
        guard !path.isEmpty else { return nil }
        guard let disk = YYDiskCache(path: path) else { return nil }
        let memory = YYMemoryCache(name: (path as NSString).lastPathComponent)
        self.name = (path as NSString).lastPathComponent
        self.diskCache = disk
        self.memoryCache = memory
    }

    deinit {
        // 资源自动释放
    }

    // MARK: - 核心接口
    /// 判断缓存中是否存在指定 key
    public func containsObject(forKey key: String) -> Bool {
        return memoryCache.containsObject(forKey: key) || diskCache.containsObject(forKey: key)
    }

    /// 异步判断缓存中是否存在指定 key
    public func containsObject(forKey key: String, withBlock block: @escaping (String, Bool) -> Void) {
        DispatchQueue.global().async {
            let result = self.containsObject(forKey: key)
            block(key, result)
        }
    }

    /// 获取指定 key 对应的对象（优先内存，磁盘命中自动写回内存）
    public func object(forKey key: String) -> Data? {
        if let obj = memoryCache.object(forKey: key as NSString) as? Data {
            return obj
        }
        if let obj = diskCache.object(forKey: key) {
            memoryCache.setObject(obj as AnyObject, forKey: key as NSString)
            return obj
        }
        return nil
    }

    /// 异步获取指定 key 对应的对象
    public func object(forKey key: String, withBlock block: @escaping (String, Data?) -> Void) {
        DispatchQueue.global().async {
            let obj = self.object(forKey: key)
            block(key, obj)
        }
    }

    /// 设置指定 key 的对象（同步）
    public func setObject(_ object: Data, forKey key: String) {
        memoryCache.setObject(object as AnyObject, forKey: key as NSString)
        diskCache.setObject(object, forKey: key)
    }

    /// 异步设置指定 key 的对象
    public func setObject(_ object: Data, forKey key: String, withBlock block: (() -> Void)? = nil) {
        DispatchQueue.global().async {
            self.setObject(object, forKey: key)
            block?()
        }
    }

    /// 移除指定 key 的对象（同步）
    public func removeObject(forKey key: String) {
        memoryCache.removeObject(forKey: key as NSString)
        diskCache.removeObject(forKey: key)
    }

    /// 异步移除指定 key 的对象
    public func removeObject(forKey key: String, withBlock block: ((String) -> Void)? = nil) {
        DispatchQueue.global().async {
            self.removeObject(forKey: key)
            block?(key)
        }
    }

    /// 清空缓存（同步）
    public func removeAllObjects() {
        memoryCache.removeAllObjects()
        diskCache.removeAllObjects()
    }

    /// 异步清空缓存
    public func removeAllObjects(withBlock block: (() -> Void)? = nil) {
        DispatchQueue.global().async {
            self.removeAllObjects()
            block?()
        }
    }

    /// 带进度回调的异步清空缓存
    public func removeAllObjects(withProgressBlock progress: ((Int, Int) -> Void)?, endBlock end: ((Bool) -> Void)?) {
        DispatchQueue.global().async {
            self.removeAllObjects()
            progress?(1, 1)
            end?(false)
        }
    }
} 
