//
//  MetadataManager.swift
//
//
//  Created by yinglun on 2019/12/18.
//

import Foundation

public struct MetadataOptions : OptionSet {
    public var rawValue: UInt
    
    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }
}

public protocol MetadataOperation: class {
    func cancel()
}

public class MetadataCombinedOperation<Provider: MetadataLoadOperationProvider>: MetadataOperation {
    public typealias OP = Provider.OP
    public var isCancelled: Bool = false
    private let lock = UnfairLock()
    public var loadToken: MetadataLoadToken<OP>?
    public var cacheOperation: Operation?
    public weak var manager: MetadataManager<Provider>?
    
    public func cancel() {
        self.lock.lock()
        self.isCancelled = true
        if let cacheOperation = self.cacheOperation {
            cacheOperation.cancel()
            self.cacheOperation = nil
        }
        if let token = self.loadToken {
            self.manager?.metadataLoader.cancel(token)
            self.loadToken = nil
        }
        self.manager?.safelyRemoveOperationFromRunning(operation: self)
        self.lock.unlock()
    }
}

public class MetadataManager<Provider: MetadataLoadOperationProvider> {
    
    public typealias OP = Provider.OP
    public typealias A = OP.A
    public typealias M = OP.M
    
    public typealias ProgressHandler = (Double) -> Void
    public typealias CompletionHandler = (M?, Error?, MetadataCacheType, Bool, A?) -> Void
        
    public let metadataCache: MetadataCache<M>
    public let metadataLoader: MetadataLoader<Provider>
    
    private var runningOperations: [MetadataCombinedOperation<Provider>] = []
    private let operationsLock = UnfairLock()
    
    /// Convenience init
    public convenience init(namespace ns: String, diskCacheDirectory dir: FileManager.SearchPathDirectory = .cachesDirectory) {
        self.init(cache: .init(namespace: ns, diskCacheDirectory: dir), loader: MetadataLoader<Provider>())
    }
    
    /// Allows to specify instance of cache and metadata loader used with metadata manager.
    public init(cache: MetadataCache<M>, loader: MetadataLoader<Provider>) {
        self.metadataCache = cache
        self.metadataLoader = loader
    }
    
    /// Loads the metadata for the given asset if not present in cache or return the cached version otherwise.
    @discardableResult
    public func loadMetadata(asset: A?, options: MetadataOptions = [], progressHandler: ProgressHandler? = nil, completionHandler: CompletionHandler?) -> MetadataOperation? {
        
        let operation = MetadataCombinedOperation<Provider>()
        operation.manager = self
        
        guard let asset = asset else {
            self.callCompletionHanlder(forOperation: operation, completionHandler: completionHandler, error: NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist, userInfo: nil), asset: nil)
            return operation
        }
        
        operationsLock.lock()
        self.runningOperations.append(operation)
        operationsLock.unlock()
        
        let key = self.cacheKey(for: asset)
        
        let cacheOptions: MetadataCacheOptions = []
        
        let cacheOperation = metadataCache.queryCacheOperation(forKey: key, options: cacheOptions) { [weak weakOperation = operation] (cachedMetadata, cacheType) in
            
            guard let strongOperation = weakOperation, strongOperation.isCancelled == false else {
                self.safelyRemoveOperationFromRunning(operation: weakOperation)
                return
            }
            
            // Check whether we should load metadata
            let shouldLoad = (cachedMetadata == nil)
            
            if shouldLoad {
                
                let loaderOptions: MetadataLoaderOptions = []
                
                let loadToken = self.metadataLoader.loadMetadata(with: asset, options: loaderOptions, progressHandler: progressHandler) { [weak weakSubOperation = strongOperation] (downloadedMetadata, error, finished) in
                    
                    defer {
                        if finished {
                            self.safelyRemoveOperationFromRunning(operation: weakSubOperation)
                        }
                    }
                    
                    guard let strongSubOperation = weakSubOperation, strongSubOperation.isCancelled == false else {
                        // Do nothing if the operation was cancelled
                        return
                    }
                    
                    if let err = error {
                        self.callCompletionHanlder(forOperation: strongSubOperation, completionHandler: completionHandler, error: err, asset: asset)
                    } else {
                        
                        let cacheOnDisk = true
                        
                        if let metdatadata = downloadedMetadata, finished {
                            self.metadataCache.store(metdatadata, forKey: key, toDisk: cacheOnDisk, completionHandler: nil)
                        }
                        self.callCompletionHanlder(forOperation: strongSubOperation, completionHandler: completionHandler, metadata: downloadedMetadata, error: nil, cacheType: .none, finished: finished, asset: asset)
                    }

                }
                strongOperation.loadToken = loadToken
                
            } else if let metadata = cachedMetadata {
                self.callCompletionHanlder(forOperation: strongOperation, completionHandler: completionHandler, metadata: metadata, error: nil, cacheType: cacheType, finished: true, asset: asset)
                self.safelyRemoveOperationFromRunning(operation: strongOperation)
            } else {
                // Metadata not in cache and load disallowed by delegate
                self.callCompletionHanlder(forOperation: strongOperation, completionHandler: completionHandler, metadata: nil, error: nil, cacheType: .none, finished: true, asset: asset)
                self.safelyRemoveOperationFromRunning(operation: strongOperation)
            }
            
        }
        operation.cacheOperation = cacheOperation
        
        return operation
    }
    
    /// Saves metadata to cache for given asset
    public func saveMetadata(toCache metadata: M?, for asset: A?) {
        if metadata != nil && asset != nil {
            let key = cacheKey(for: asset)
            metadataCache.store(metadata, forKey: key, toDisk: true, completionHandler: nil)
        }
    }
    
    /// Cancel all current operations
    public func cancelAll() {
        operationsLock.lock()
        let operations = runningOperations
        for (index, operation) in operations.enumerated() {
            operation.cancel()
            runningOperations.remove(at: index)
        }
        operationsLock.unlock()
    }
    
    /// Check one or more operations running
    public func isRunning() -> Bool {
        var result = false
        operationsLock.lock()
        result = runningOperations.count > 0
        operationsLock.unlock()
        return result
    }
    
    /// Async check if metadata has already been cached
    public func cachedMetadataExists(for asset: A?, completionHandler: MetadataCheckCacheCompletionHandler?) {
        let key = cacheKey(for: asset)
        
        let isInMemoryCache = metadataCache.metadataFromMemoryCache(forKey: key) != nil
        
        if isInMemoryCache {
            DispatchQueue.main.safeAsync {
                completionHandler?(true)
            }
            return
        }
        
        metadataCache.diskMetadataExists(withKey: key) { (isInDiskCache) in
             // the completion block of diskMetadataExists:completion: is always called on the main queue, no need to further dispatch
            completionHandler?(isInDiskCache)
        }
    }
    
    /// Async check if metadata has already been cached on disk only
    public func diskMetadataExists(for asset: A?, completionHandler: MetadataCheckCacheCompletionHandler?) {
        
        let key = cacheKey(for: asset)

        metadataCache.diskMetadataExists(withKey: key) { (isInDiskCache) in
            // the completion block of diskMetadataExists:completion: is always called on the main queue, no need to further dispatch
            completionHandler?(isInDiskCache)
        }
    }
    
    /// Return the cache key for a given asset
    public func cacheKey(for asset: A?) -> String? {
        return asset?.identifier
    }
    
    fileprivate func safelyRemoveOperationFromRunning(operation: MetadataCombinedOperation<Provider>?) {
        
        if let op = operation {
            operationsLock.lock()
            if let index = runningOperations.firstIndex(where: { $0 === op }) {
                runningOperations.remove(at: index)
            }
            operationsLock.unlock()
        }
    }
    
    private func callCompletionHanlder(forOperation operation: MetadataCombinedOperation<Provider>?, completionHandler: CompletionHandler?, metadata: M? = nil, error: Error?, cacheType: MetadataCacheType = .none, finished: Bool = false, asset: A?) {
        
        DispatchQueue.main.safeAsync {
            if let op = operation, op.isCancelled == false, let cb = completionHandler {
                cb(metadata, error, cacheType, finished, asset)
            }
        }
    }
    
}
