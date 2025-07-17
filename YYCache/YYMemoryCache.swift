//
//  YYMemoryCache.swift
//  YYCache <https://github.com/ibireme/YYCache>
//
//  由 ibireme 创建于 2015/2/7。
//  本源码遵循 MIT 协议，详见根目录 LICENSE 文件。
//

import Foundation
import QuartzCore
import UIKit

/// LRU 链表节点，内部使用
private class _YYLinkedMapNode {
    weak var prev: _YYLinkedMapNode?
    weak var next: _YYLinkedMapNode?
    var key: AnyObject?
    var value: AnyObject?
    var cost: UInt = 0
    var time: TimeInterval = 0
}

/// LRU 链表，内部使用
private class _YYLinkedMap {
    private var dict = [AnyHashable: _YYLinkedMapNode]()
    var totalCost: UInt = 0
    var totalCount: UInt = 0
    var head: _YYLinkedMapNode?
    var tail: _YYLinkedMapNode?
    var releaseOnMainThread = false
    var releaseAsynchronously = true

    /// 插入节点到头部
    func insertNodeAtHead(_ node: _YYLinkedMapNode) {
        dict[node.key as! AnyHashable] = node
        totalCost += node.cost
        totalCount += 1
        if let h = head {
            node.next = h
            h.prev = node
            head = node
        } else {
            head = node
            tail = node
        }
    }

    /// 将节点移到头部
    func bringNodeToHead(_ node: _YYLinkedMapNode) {
        if head === node { return }
        if tail === node {
            tail = node.prev
            tail?.next = nil
        } else {
            node.next?.prev = node.prev
            node.prev?.next = node.next
        }
        node.next = head
        node.prev = nil
        head?.prev = node
        head = node
    }

    /// 移除节点
    func removeNode(_ node: _YYLinkedMapNode) {
        dict.removeValue(forKey: node.key as! AnyHashable)
        totalCost -= node.cost
        totalCount -= 1
        if let next = node.next { next.prev = node.prev }
        if let prev = node.prev { prev.next = node.next }
        if head === node { head = node.next }
        if tail === node { tail = node.prev }
    }

    /// 移除尾节点
    func removeTailNode() -> _YYLinkedMapNode? {
        guard let t = tail else { return nil }
        dict.removeValue(forKey: t.key as! AnyHashable)
        totalCost -= t.cost
        totalCount -= 1
        if head === tail {
            head = nil
            tail = nil
        } else {
            tail = t.prev
            tail?.next = nil
        }
        return t
    }

    /// 移除所有节点
    func removeAll() {
        totalCost = 0
        totalCount = 0
        head = nil
        tail = nil
        dict.removeAll()
    }

    /// 是否包含 key
    func contains(_ key: AnyHashable) -> Bool {
        return dict[key] != nil
    }

    /// 获取节点
    func node(for key: AnyHashable) -> _YYLinkedMapNode? {
        return dict[key]
    }
}

/// 高性能线程安全 LRU 内存缓存，所有方法等价于 OC 版 YYMemoryCache
public class YYMemoryCache {
    // MARK: - 属性
    public var name: String?
    public var countLimit: UInt = UInt.max
    public var costLimit: UInt = UInt.max
    public var ageLimit: TimeInterval = Double.greatestFiniteMagnitude
    public var autoTrimInterval: TimeInterval = 5.0
    public var shouldRemoveAllObjectsOnMemoryWarning: Bool = true
    public var shouldRemoveAllObjectsWhenEnteringBackground: Bool = true
    public var didReceiveMemoryWarningBlock: ((YYMemoryCache) -> Void)?
    public var didEnterBackgroundBlock: ((YYMemoryCache) -> Void)?
    public var releaseOnMainThread: Bool {
        get { lock.lock(); defer { lock.unlock() }; return lru.releaseOnMainThread }
        set { lock.lock(); lru.releaseOnMainThread = newValue; lock.unlock() }
    }
    public var releaseAsynchronously: Bool {
        get { lock.lock(); defer { lock.unlock() }; return lru.releaseAsynchronously }
        set { lock.lock(); lru.releaseAsynchronously = newValue; lock.unlock() }
    }
    public var totalCount: UInt { lock.lock(); defer { lock.unlock() }; return lru.totalCount }
    public var totalCost: UInt { lock.lock(); defer { lock.unlock() }; return lru.totalCost }

    // MARK: - 内部
    private let lock = NSLock()
    private let lru = _YYLinkedMap()
    private let queue = DispatchQueue(label: "com.ibireme.cache.memory", qos: .utility)
    private var timer: DispatchSourceTimer?

    // MARK: - 初始化
    public init(name: String? = nil) {
        self.name = name
        NotificationCenter.default.addObserver(self, selector: #selector(_appDidReceiveMemoryWarningNotification), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(_appDidEnterBackgroundNotification), name: UIApplication.didEnterBackgroundNotification, object: nil)
        _trimRecursively()
    }
    deinit {
        NotificationCenter.default.removeObserver(self)
        lru.removeAll()
    }

    // MARK: - 自动 trim
    private func _trimRecursively() {
        timer?.cancel()
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer?.schedule(deadline: .now() + autoTrimInterval, repeating: autoTrimInterval)
        timer?.setEventHandler { [weak self] in
            self?._trimInBackground()
            self?._trimRecursively()
        }
        timer?.resume()
    }
    private func _trimInBackground() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self._trimToCost(self.costLimit)
            self._trimToCount(self.countLimit)
            self._trimToAge(self.ageLimit)
        }
    }
    // MARK: - trim 逻辑
    private func _trimToCost(_ costLimit: UInt) {
        var finish = false
        lock.lock()
        if costLimit == 0 {
            lru.removeAll(); finish = true
        } else if lru.totalCost <= costLimit {
            finish = true
        }
        lock.unlock()
        if finish { return }
        var holder = [_YYLinkedMapNode]()
        while !finish {
            if lock.try() {
                if lru.totalCost > costLimit, let node = lru.removeTailNode() {
                    holder.append(node)
                } else {
                    finish = true
                }
                lock.unlock()
            } else {
                usleep(10_000)
            }
        }
        if !holder.isEmpty {
            let queue = lru.releaseOnMainThread ? DispatchQueue.main : DispatchQueue.global(qos: .background)
            queue.async { _ = holder.count }
        }
    }
    private func _trimToCount(_ countLimit: UInt) {
        var finish = false
        lock.lock()
        if countLimit == 0 {
            lru.removeAll(); finish = true
        } else if lru.totalCount <= countLimit {
            finish = true
        }
        lock.unlock()
        if finish { return }
        var holder = [_YYLinkedMapNode]()
        while !finish {
            if lock.try() {
                if lru.totalCount > countLimit, let node = lru.removeTailNode() {
                    holder.append(node)
                } else {
                    finish = true
                }
                lock.unlock()
            } else {
                usleep(10_000)
            }
        }
        if !holder.isEmpty {
            let queue = lru.releaseOnMainThread ? DispatchQueue.main : DispatchQueue.global(qos: .background)
            queue.async { _ = holder.count }
        }
    }
    private func _trimToAge(_ ageLimit: TimeInterval) {
        var finish = false
        let now = CACurrentMediaTime()
        lock.lock()
        if ageLimit <= 0 {
            lru.removeAll(); finish = true
        } else if lru.tail == nil || (now - (lru.tail?.time ?? 0)) <= ageLimit {
            finish = true
        }
        lock.unlock()
        if finish { return }
        var holder = [_YYLinkedMapNode]()
        while !finish {
            if lock.try() {
                if let tail = lru.tail, (now - tail.time) > ageLimit, let node = lru.removeTailNode() {
                    holder.append(node)
                } else {
                    finish = true
                }
                lock.unlock()
            } else {
                usleep(10_000)
            }
        }
        if !holder.isEmpty {
            let queue = lru.releaseOnMainThread ? DispatchQueue.main : DispatchQueue.global(qos: .background)
            queue.async { _ = holder.count }
        }
    }

    // MARK: - 系统通知
    @objc private func _appDidReceiveMemoryWarningNotification() {
        didReceiveMemoryWarningBlock?(self)
        if shouldRemoveAllObjectsOnMemoryWarning {
            removeAllObjects()
        }
    }
    @objc private func _appDidEnterBackgroundNotification() {
        didEnterBackgroundBlock?(self)
        if shouldRemoveAllObjectsWhenEnteringBackground {
            removeAllObjects()
        }
    }

    // MARK: - 公共方法
    public func containsObject(forKey key: AnyHashable?) -> Bool {
        guard let key = key else { return false }
        lock.lock(); defer { lock.unlock() }
        return lru.contains(key)
    }
    public func object(forKey key: AnyHashable?) -> AnyObject? {
        guard let key = key else { return nil }
        lock.lock()
        let node = lru.node(for: key)
        if let node = node {
            node.time = CACurrentMediaTime()
            lru.bringNodeToHead(node)
        }
        lock.unlock()
        return node?.value
    }
    public func setObject(_ object: AnyObject?, forKey key: AnyHashable?, cost: UInt = 0) {
        guard let key = key else { return }
        guard let object = object else {
            removeObject(forKey: key)
            return
        }
        lock.lock()
        var node = lru.node(for: key)
        let now = CACurrentMediaTime()
        if let n = node {
            lru.totalCost -= n.cost
            lru.totalCost += cost
            n.cost = cost
            n.time = now
            n.value = object
            lru.bringNodeToHead(n)
        } else {
            node = _YYLinkedMapNode()
            node!.cost = cost
            node!.time = now
            node!.key = key as AnyObject
            node!.value = object
            lru.insertNodeAtHead(node!)
        }
        if lru.totalCost > costLimit {
            queue.async { [weak self] in self?.trimToCost(self?.costLimit ?? 0) }
        }
        if lru.totalCount > countLimit {
            if let node = lru.removeTailNode() {
                let queue = lru.releaseOnMainThread ? DispatchQueue.main : DispatchQueue.global(qos: .background)
                if lru.releaseAsynchronously {
                    queue.async { _ = node }
                } else if lru.releaseOnMainThread && !Thread.isMainThread {
                    DispatchQueue.main.async { _ = node }
                }
            }
        }
        lock.unlock()
    }
    public func removeObject(forKey key: AnyHashable?) {
        guard let key = key else { return }
        lock.lock()
        if let node = lru.node(for: key) {
            lru.removeNode(node)
            let queue = lru.releaseOnMainThread ? DispatchQueue.main : DispatchQueue.global(qos: .background)
            if lru.releaseAsynchronously {
                queue.async { _ = node }
            } else if lru.releaseOnMainThread && !Thread.isMainThread {
                DispatchQueue.main.async { _ = node }
            }
        }
        lock.unlock()
    }
    public func removeAllObjects() {
        lock.lock(); lru.removeAll(); lock.unlock()
    }
    public func trimToCount(_ count: UInt) {
        if count == 0 { removeAllObjects(); return }
        _trimToCount(count)
    }
    public func trimToCost(_ cost: UInt) {
        _trimToCost(cost)
    }
    public func trimToAge(_ age: TimeInterval) {
        _trimToAge(age)
    }
} 
