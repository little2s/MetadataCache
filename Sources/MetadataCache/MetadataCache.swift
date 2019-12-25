//
//  MetadataCache.swift
//
//
//  Created by yinglun on 2019/12/18.
//

import Foundation

public enum MetadataCacheType {
    /// The metadata wasn't available the caches, but was loaded.
    case none
    
    /// The metadata was obtained from the disk cache.
    case disk
    
    /// The metadata was obtained from the memory cache.
    case memory
}

public struct MetadataCacheOptions: OptionSet {
    public var rawValue: UInt
    
    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }
    
    /// By default, we do not query disk data when the metadata is cached in memory. This mask can force to query disk data at the same time.
    public static let queryDataWhenInMemory = MetadataCacheOptions(rawValue: 1 << 0)
    
    /// By default, we query the memory cache synchronously, disk cache asynchronously. This mask can force to query disk cache synchronously.
    public static let queryDiskSync = MetadataCacheOptions(rawValue: 1 << 1)
    
}

public struct MetadataCacheConfig {
    
    public var shouldCacheMetadataInMemory = true

}

public typealias MetadataCheckCacheCompletionHandler = (Bool) -> Void
public typealias MetadataCalculateSizeHandler = (UInt, UInt) -> Void

fileprivate final class Wrapper<T> {
    let value: T
    init(value: T) {
        self.value = value
    }
}

public class MetadataCache<M> where M: Metadata {
    
    public typealias DiskCacheDirectory = FileManager.SearchPathDirectory
    public typealias CacheQueryCompletionHandler = (M?, MetadataCacheType) -> Void
    
    private typealias WrappedM = Wrapper<M>
    
    public var config = MetadataCacheConfig()
    
    /// The maximum number of objects the cache should hold. Default value is `500`.
    public var maxMemoryCountLimit: Int {
        set { memoryCache.countLimit = newValue }
        get { return memoryCache.countLimit }
    }
    
    private let memoryCache: NSCache<NSString, WrappedM>
    private let diskCache: KeyedPersistenceDirectory
    private let ioQueue: DispatchQueue
    private let fileManager: FileManager
    
    /// Init a new cache store with a specific namespace and directory
    public init(namespace ns: String, diskCacheDirectory directory: DiskCacheDirectory) {
        let fullNamespace = "com.meteor.MetadataCache<\(M.self)>.\(ns)"
        
        memoryCache = NSCache<NSString, WrappedM>()
        memoryCache.name = fullNamespace
        memoryCache.countLimit = 500
        
        diskCache = KeyedPersistenceDirectory(name: ns, directory: directory)
        
        ioQueue = DispatchQueue(label: "com.meteor.MetadataCache<\(M.self)>.io")
        
        fileManager = FileManager()
    }
    
    /// Asynchronously store an metadata into memory and disk cache at the given key.
    public func store(_ metadata: M?, forKey key: String?, toDisk: Bool = true, completionHandler: (() -> Void)? = nil) {
        guard let mtd = metadata, let key = key else {
            completionHandler?()
            return
        }
        // if memory cache is enabled
        if config.shouldCacheMetadataInMemory {
            memoryCache.setObject(WrappedM(value: mtd), forKey: key as NSString)
        }
        
        if toDisk {
            ioQueue.async {
                do {
                    let data = try mtd.encodeToData()
                    try self.diskCache.save(data: data, for: key)
                } catch {
                    print(error)
                }

                DispatchQueue.main.async {
                    completionHandler?()
                }
            }
            
        } else {
            completionHandler?()
        }
    }
    
    /// Async check if metadata exists in disk cache already (does not load the metadata)
    public func diskMetadataExists(withKey key: String?, completionHandler: MetadataCheckCacheCompletionHandler? = nil) {
        ioQueue.async {
            let exists = self._diskMetadataExists(withKey: key)
            DispatchQueue.main.async {
                completionHandler?(exists)
            }
        }
    }
    
    /// Sync check if metadata exists in disk cache already (does not load the metadata)
    public func diskMetadataExists(withKey key: String?) -> Bool {
        var exists = false
        ioQueue.sync {
            exists = self._diskMetadataExists(withKey: key)
        }
        return exists
    }
    
    private func _diskMetadataExists(withKey key: String?) -> Bool {
        guard let key = key else {
            return false
        }
        
        let url = diskCache.fileURL(for: key)
        let exists = fileManager.fileExists(atPath: url.path)
        return exists
    }
    
    /// Operation that queries the cache asynchronously and call the completion when done.
    @discardableResult
    public func queryCacheOperation(forKey key: String?, options: MetadataCacheOptions = [], completionHandler: CacheQueryCompletionHandler? = nil) -> Operation? {
        
        guard let key = key else {
            completionHandler?(nil, .none)
            return nil
        }
        
        // First check the in-memory cache...
        let metadata = metadataFromMemoryCache(forKey: key)
        let shouldQueryMemoryOnly = (metadata != nil) && options.contains(.queryDataWhenInMemory)
        if shouldQueryMemoryOnly {
            completionHandler?(metadata, .memory)
            return nil
        }
        
        let operation = Operation()
        let queryDiskClosure: () -> Void = {
            if operation.isCancelled {
                // do not call the completion if cancelled
                return
            }
            
            var diskMetadata: M?
            var cacheType: MetadataCacheType = .disk
            if metadata != nil {
                // the image is from in-memory cache
                diskMetadata = metadata
                cacheType = .memory
            } else {
                diskMetadata = self._diskMetadata(forKey: key)
                if let mtd = diskMetadata, self.config.shouldCacheMetadataInMemory {
                    self.memoryCache.setObject(WrappedM(value: mtd), forKey: key as NSString)
                }
            }
            
            if options.contains(.queryDiskSync) {
                completionHandler?(diskMetadata, cacheType)
            } else {
                DispatchQueue.main.async {
                    completionHandler?(diskMetadata, cacheType)
                }
            }
        }
        
        if options.contains(.queryDiskSync) {
            queryDiskClosure()
        } else {
            ioQueue.async {
                queryDiskClosure()
            }
        }
        
        return operation
    }
    
    /// Query the memory cache synchronously.
    public func metadataFromMemoryCache(forKey key: String?) -> M? {
        if let key = key {
            return memoryCache.object(forKey: key as NSString)?.value
        }
        return nil
    }
    
    /// Query the disk cache synchronously.
    public func metadataFromDiskCache(forKey key: String?) -> M? {
        guard let key = key else {
            return nil
        }
        
        var diskMetadata: M?
        ioQueue.sync {
            diskMetadata = self._diskMetadata(forKey: key)
        }
        if let mtd = diskMetadata, config.shouldCacheMetadataInMemory {
            memoryCache.setObject(WrappedM(value: mtd), forKey: key as NSString)
        }
        return diskMetadata
    }
    
    public func metadataFromCache(forKey key: String?) -> M? {
        // First check the in-memory cache...
        var metadata = metadataFromMemoryCache(forKey: key)
        if metadata != nil {
            return metadata
        }
        
        // Second check the disk cache...
        metadata = metadataFromDiskCache(forKey: key)
        return metadata
    }
    
    private func _diskMetadata(forKey key: String?) -> M? {
        if let key = key, let data = diskCache.data(for: key) {
            return try? M.decodeFromData(data)
        }
        return nil
    }
    
    /// Remove the metadta from memory and optionally disk cache asynchronously
    public func removeMetadata(forKey key: String?, fromDisk: Bool = true, completionHandler: (() -> Void)? = nil) {
        guard let key = key else {
            completionHandler?()
            return
        }
        
        if config.shouldCacheMetadataInMemory {
            memoryCache.removeObject(forKey: key as NSString)
        }
        
        if fromDisk {
            ioQueue.async {
                let url = self.diskCache.fileURL(for: key)
                try? self.fileManager.removeItem(at: url)
                
                DispatchQueue.main.async {
                    completionHandler?()
                }
            }
        } else {
            completionHandler?()
        }
    }
    
    /// Clear all memory cached images
    public func clearMemory() {
        memoryCache.removeAllObjects()
    }
    
    /// Async clear all disk cached metadata. Non-blocking method - returns immediately.
    public func clearDisk(completionHandler: (() -> Void)? = nil) {
        ioQueue.async {
            self.diskCache.clear()
            DispatchQueue.main.async {
                completionHandler?()
            }
        }
    }
    
    /// Get the cache path for a certain key
    public func cachePath(forKey key: String?) -> String? {
        guard let key = key else {
            return nil
        }
        
        var path: String?
        ioQueue.sync {
            let url = self.diskCache.fileURL(for: key)
            path = url.path
        }
        return path
    }

}
