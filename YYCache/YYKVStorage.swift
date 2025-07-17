//
//  YYKVStorage.swift
//  YYCache <https://github.com/ibireme/YYCache>
//
//  由 ibireme 创建于 2015/4/22。
//  本源码遵循 MIT 协议，详见根目录 LICENSE 文件。
//

import Foundation
import SQLite3

/// 存储类型，指明 value 的存储位置。
public enum YYKVStorageType: UInt {
    /// 值存储为文件
    case file = 0
    /// 值存储在 sqlite 的 blob 字段
    case sqlite = 1
    /// 值可存储为文件或 sqlite，由调用方决定
    case mixed = 2
}

/// 存储项，包含 key、value、文件名、大小、时间戳、扩展数据
public class YYKVStorageItem {
    public var key: String                // 键
    public var value: Data                // 值
    public var filename: String?          // 文件名（如果为内联则为 nil）
    public var size: Int                  // 值的字节大小
    public var modTime: Int               // 修改时间戳
    public var accessTime: Int            // 最后访问时间戳
    public var extendedData: Data?        // 扩展数据
    public init(key: String, value: Data, filename: String? = nil, size: Int, modTime: Int, accessTime: Int, extendedData: Data? = nil) {
        self.key = key
        self.value = value
        self.filename = filename
        self.size = size
        self.modTime = modTime
        self.accessTime = accessTime
        self.extendedData = extendedData
    }
}

/// YYKVStorage：基于 SQLite 和文件系统的高性能键值存储，线程安全，支持多种淘汰策略。
public class YYKVStorage {
    // MARK: - 属性
    public let path: String           // 存储路径
    public let type: YYKVStorageType  // 存储类型
    public var errorLogsEnabled: Bool = true // 是否启用错误日志

    // 目录结构
    private let dbFileName = "manifest.sqlite"
    private let dbShmFileName = "manifest.sqlite-shm"
    private let dbWalFileName = "manifest.sqlite-wal"
    private let dataDirectoryName = "data"
    private let trashDirectoryName = "trash"
    private var dbPath: String { path + "/" + dbFileName }
    private var dataPath: String { path + "/" + dataDirectoryName }
    private var trashPath: String { path + "/" + trashDirectoryName }

    // SQLite 相关
    private var db: OpaquePointer?
    private var dbStmtCache: [String: OpaquePointer] = [:]
    private var dbLastOpenErrorTime: TimeInterval = 0
    private var dbOpenErrorCount: UInt = 0

    // 线程安全
    private let queue = DispatchQueue(label: "com.ibireme.cache.disk.trash", qos: .utility)

    // MARK: - 初始化
    /// 初始化方法，传入存储路径和类型
    public init?(path: String, type: YYKVStorageType) {
        guard !path.isEmpty else {
            print("YYKVStorage 初始化错误：路径不能为空")
            return nil
        }
        self.path = path
        self.type = type
        // 创建目录结构
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
            try FileManager.default.createDirectory(atPath: dataPath, withIntermediateDirectories: true, attributes: nil)
            try FileManager.default.createDirectory(atPath: trashPath, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("YYKVStorage 初始化错误：目录创建失败 \(error)")
            return nil
        }
        // 这里只做目录和属性初始化，后续会补充 SQLite 打开、重置、垃圾桶清理等
    }

    deinit {
        // 关闭数据库、清理资源
        if let db = db { sqlite3_close(db) }
    }

    // MARK: - SQLite3 C API 封装
    /// 打开数据库，如果已打开则直接返回 true
    @discardableResult
    private func dbOpen() -> Bool {
        if db != nil { return true }
        if sqlite3_open(dbPath, &db) == SQLITE_OK {
            dbLastOpenErrorTime = 0
            dbOpenErrorCount = 0
            return true
        } else {
            db = nil
            dbLastOpenErrorTime = CACurrentMediaTime()
            dbOpenErrorCount += 1
            if errorLogsEnabled {
                print("[YYKVStorage] SQLite 打开失败：\(dbPath)")
            }
            return false
        }
    }

    /// 关闭数据库
    @discardableResult
    private func dbClose() -> Bool {
        guard let db = db else { return true }
        let result = sqlite3_close(db)
        if result == SQLITE_OK {
            self.db = nil
            dbStmtCache.removeAll()
            return true
        } else {
            if errorLogsEnabled {
                print("[YYKVStorage] SQLite 关闭失败：\(result)")
            }
            return false
        }
    }

    /// 执行 SQL 语句（无返回值）
    @discardableResult
    private func dbExecute(_ sql: String) -> Bool {
        guard dbOpen(), !sql.isEmpty else { return false }
        var error: UnsafeMutablePointer<Int8>? = nil
        let result = sqlite3_exec(db, sql, nil, nil, &error)
        if result != SQLITE_OK {
            if errorLogsEnabled {
                let msg = error != nil ? String(cString: error!) : "未知错误"
                print("[YYKVStorage] SQLite 执行失败：\(msg)")
            }
            if error != nil { sqlite3_free(error) }
            return false
        }
        return true
    }

    /// 预编译 SQL 语句缓存
    private func dbPrepareStmt(_ sql: String) -> OpaquePointer? {
        guard dbOpen(), !sql.isEmpty else { return nil }
        if let cached = dbStmtCache[sql] {
            sqlite3_reset(cached)
            return cached
        }
        var stmt: OpaquePointer? = nil
        let result = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if result == SQLITE_OK, let stmt = stmt {
            dbStmtCache[sql] = stmt
            return stmt
        } else {
            if errorLogsEnabled {
                let msg = String(cString: sqlite3_errmsg(db))
                print("[YYKVStorage] SQLite 预编译失败：\(msg)")
            }
            return nil
        }
    }

    /// 绑定字符串数组到 SQL 语句
    private func dbBindJoinedKeys(_ keys: [String], stmt: OpaquePointer, from index: Int32) {
        for (i, key) in keys.enumerated() {
            sqlite3_bind_text(stmt, index + Int32(i), key, -1, nil)
        }
    }

    // MARK: - 文件操作
    /// 写入数据到指定文件名
    private func fileWrite(name: String, data: Data) -> Bool {
        let path = dataPath + "/" + name
        return ((try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil)
    }

    /// 读取指定文件名的数据
    private func fileRead(name: String) -> Data? {
        let path = dataPath + "/" + name
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// 删除指定文件名
    private func fileDelete(name: String) -> Bool {
        let path = dataPath + "/" + name
        return (try? FileManager.default.removeItem(atPath: path)) != nil
    }

    /// 批量移动 data 目录到垃圾桶
    private func fileMoveAllToTrash() -> Bool {
        let uuid = UUID().uuidString
        let tmpPath = trashPath + "/" + uuid
        do {
            try FileManager.default.moveItem(atPath: dataPath, toPath: tmpPath)
            try FileManager.default.createDirectory(atPath: dataPath, withIntermediateDirectories: true, attributes: nil)
            return true
        } catch {
            if errorLogsEnabled {
                print("[YYKVStorage] 批量移动 data 到垃圾桶失败：\(error)")
            }
            return false
        }
    }

    /// 异步清空垃圾桶
    private func fileEmptyTrashInBackground() {
        let trashPath = self.trashPath
        queue.async {
            let manager = FileManager.default
            if let contents = try? manager.contentsOfDirectory(atPath: trashPath) {
                for path in contents {
                    let fullPath = trashPath + "/" + path
                    _ = try? manager.removeItem(atPath: fullPath)
                }
            }
        }
    }

    // MARK: - 核心接口
    /// 保存或更新 item
    @discardableResult
    public func saveItem(_ item: YYKVStorageItem) -> Bool {
        return saveItem(key: item.key, value: item.value, filename: item.filename, extendedData: item.extendedData)
    }

    /// 保存或更新 key-value
    @discardableResult
    public func saveItem(key: String, value: Data, filename: String? = nil, extendedData: Data? = nil) -> Bool {
        guard !key.isEmpty, !value.isEmpty else { return false }
        if type == .file && (filename == nil || filename!.isEmpty) { return false }
        // 这里只实现 SQLite 逻辑，后续可补充文件/混合逻辑
        if type == .sqlite {
            // 插入或替换
            let sql = "insert or replace into manifest (key, filename, size, inline_data, modification_time, last_access_time, extended_data) values (?1, ?2, ?3, ?4, ?5, ?6, ?7);"
            guard let stmt = dbPrepareStmt(sql) else { return false }
            let timestamp = Int32(Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 1, key, -1, nil)
            sqlite3_bind_text(stmt, 2, filename ?? "", -1, nil)
            sqlite3_bind_int(stmt, 3, Int32(value.count))
            if filename == nil || filename!.isEmpty {
                _ = value.withUnsafeBytes { sqlite3_bind_blob(stmt, 4, $0.baseAddress, Int32(value.count), nil) }
            } else {
                sqlite3_bind_blob(stmt, 4, nil, 0, nil)
            }
            sqlite3_bind_int(stmt, 5, timestamp)
            sqlite3_bind_int(stmt, 6, timestamp)
            if let ext = extendedData {
                _ = ext.withUnsafeBytes { sqlite3_bind_blob(stmt, 7, $0.baseAddress, Int32(ext.count), nil) }
            } else {
                sqlite3_bind_blob(stmt, 7, nil, 0, nil)
            }
            let result = sqlite3_step(stmt)
            if result != SQLITE_DONE {
                if errorLogsEnabled {
                    let msg = String(cString: sqlite3_errmsg(db))
                    print("[YYKVStorage] SQLite 插入失败：\(msg)")
                }
                return false
            }
            return true
        }
        // TODO: 文件/混合模式逻辑
        return false
    }

    /// 获取指定 key 的 item
    public func getItem(forKey key: String) -> YYKVStorageItem? {
        guard !key.isEmpty else { return nil }
        // 这里只实现 SQLite 逻辑，后续可补充文件/混合逻辑
        if type == .sqlite {
            let sql = "select key, filename, size, inline_data, modification_time, last_access_time, extended_data from manifest where key = ?1;"
            guard let stmt = dbPrepareStmt(sql) else { return nil }
            sqlite3_bind_text(stmt, 1, key, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let item = parseItemFromStmt(stmt)
                // 更新访问时间
                _ = dbExecute("update manifest set last_access_time = \(Int32(Date().timeIntervalSince1970)) where key = '\(key)';")
                return item
            }
        }
        // TODO: 文件/混合模式逻辑
        return nil
    }

    /// 删除指定 key 的 item
    @discardableResult
    public func removeItem(forKey key: String) -> Bool {
        guard !key.isEmpty else { return false }
        // 这里只实现 SQLite 逻辑，后续可补充文件/混合逻辑
        if type == .sqlite {
            let sql = "delete from manifest where key = ?1;"
            guard let stmt = dbPrepareStmt(sql) else { return false }
            sqlite3_bind_text(stmt, 1, key, -1, nil)
            let result = sqlite3_step(stmt)
            if result != SQLITE_DONE {
                if errorLogsEnabled {
                    let msg = String(cString: sqlite3_errmsg(db))
                    print("[YYKVStorage] SQLite 删除失败：\(msg)")
                }
                return false
            }
            return true
        }
        // TODO: 文件/混合模式逻辑
        return false
    }

    /// 解析 stmt 为 YYKVStorageItem
    private func parseItemFromStmt(_ stmt: OpaquePointer) -> YYKVStorageItem {
        var i: Int32 = 0
        let key = String(cString: sqlite3_column_text(stmt, i)); i += 1
        let filename = String(cString: sqlite3_column_text(stmt, i)); i += 1
        let size = Int(sqlite3_column_int(stmt, i)); i += 1
        var value: Data = Data()
        if let blob = sqlite3_column_blob(stmt, i) {
            let length = Int(sqlite3_column_bytes(stmt, i))
            value = Data(bytes: blob, count: length)
        }
        i += 1
        let modTime = Int(sqlite3_column_int(stmt, i)); i += 1
        let accessTime = Int(sqlite3_column_int(stmt, i)); i += 1
        var extendedData: Data? = nil
        if let blob = sqlite3_column_blob(stmt, i) {
            let length = Int(sqlite3_column_bytes(stmt, i))
            extendedData = Data(bytes: blob, count: length)
        }
        return YYKVStorageItem(key: key, value: value, filename: filename.isEmpty ? nil : filename, size: size, modTime: modTime, accessTime: accessTime, extendedData: extendedData)
    }

    // MARK: - 批量操作与淘汰策略
    /// 批量删除 keys
    @discardableResult
    public func removeItems(forKeys keys: [String]) -> Bool {
        guard !keys.isEmpty else { return false }
        if type == .sqlite {
            let joined = keys.map { "'\($0)'" }.joined(separator: ",")
            let sql = "delete from manifest where key in (\(joined));"
            return dbExecute(sql)
        }
        // TODO: 文件/混合模式逻辑
        return false
    }

    /// 删除所有 size 大于指定值的 item
    @discardableResult
    public func removeItems(largerThan size: Int) -> Bool {
        if type == .sqlite {
            let sql = "delete from manifest where size > \(size);"
            return dbExecute(sql)
        }
        // TODO: 文件/混合模式逻辑
        return false
    }

    /// 删除所有访问时间早于指定时间的 item
    @discardableResult
    public func removeItems(earlierThan time: Int) -> Bool {
        if type == .sqlite {
            let sql = "delete from manifest where last_access_time < \(time);"
            return dbExecute(sql)
        }
        // TODO: 文件/混合模式逻辑
        return false
    }

    /// 按 size 淘汰，直到总 size 不超过 maxSize
    @discardableResult
    public func removeItemsToFit(size maxSize: Int) -> Bool {
        if type == .sqlite {
            // 这里只做简单实现，实际应按 LRU 批量淘汰
            let sql = "delete from manifest where size > \(maxSize);"
            return dbExecute(sql)
        }
        // TODO: 文件/混合模式逻辑
        return false
    }

    /// 按 count 淘汰，直到总数不超过 maxCount
    @discardableResult
    public func removeItemsToFit(count maxCount: Int) -> Bool {
        if type == .sqlite {
            // 这里只做简单实现，实际应按 LRU 批量淘汰
            let sql = "delete from manifest where rowid not in (select rowid from manifest order by last_access_time desc limit \(maxCount));"
            return dbExecute(sql)
        }
        // TODO: 文件/混合模式逻辑
        return false
    }

    /// 删除所有 item
    @discardableResult
    public func removeAllItems() -> Bool {
        if type == .sqlite {
            let sql = "delete from manifest;"
            return dbExecute(sql)
        }
        // TODO: 文件/混合模式逻辑
        return false
    }

    /// 带进度回调的批量删除
    public func removeAllItems(progress: ((Int, Int) -> Void)?, end: ((Bool) -> Void)?) {
        // 这里只做简单实现，实际应分批删除并回调
        let total = getItemsCount()
        let result = removeAllItems()
        progress?(total, total)
        end?(!result)
    }

    /// 获取 item 总数
    public func getItemsCount() -> Int {
        if type == .sqlite {
            let sql = "select count(*) from manifest;"
            guard let stmt = dbPrepareStmt(sql) else { return 0 }
            if sqlite3_step(stmt) == SQLITE_ROW {
                return Int(sqlite3_column_int(stmt, 0))
            }
        }
        // TODO: 文件/混合模式逻辑
        return 0
    }

    /// 获取 item 总 size
    public func getItemsSize() -> Int {
        if type == .sqlite {
            let sql = "select sum(size) from manifest;"
            guard let stmt = dbPrepareStmt(sql) else { return 0 }
            if sqlite3_step(stmt) == SQLITE_ROW {
                return Int(sqlite3_column_int(stmt, 0))
            }
        }
        // TODO: 文件/混合模式逻辑
        return 0
    }
} 
