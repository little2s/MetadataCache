//
//  MetadataLoader.swift
//
//
//  Created by yinglun on 2019/12/18.
//

import Foundation

public struct MetadataLoaderOptions: OptionSet {
    
    public var rawValue: UInt
    
    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }
    
}

public final class MetadataLoadToken<OP> where OP: MetadataLoadOperation {
    
    fileprivate weak var loadOperation: OP?
    
    fileprivate(set) var asset: OP.A?
    
    fileprivate(set) var loadOperationCancelToken: Any?
    
    public func cancel() {
        if let op = loadOperation, let tk = loadOperationCancelToken {
            let _ = op.cancel(tk)
            loadOperation = nil
            asset = nil
        }
    }
    
}


public final class MetadataLoader<Provider: MetadataLoadOperationProvider> {
    
    public typealias OP = Provider.OP
    public typealias A = OP.A
    public typealias M = OP.M
    
    public typealias ProgressHandler = (Double) -> Void
    public typealias CompletionHandler = (M?, Error?, Bool) -> Void
    
    public enum ExecutionOrder: Int {
        case fifo
        case lifo
    }
    
    /// The maximum number of concurrent loads. Default value is `6`.
    public var maxConcurrentLoads: Int {
        set { loadQueue.maxConcurrentOperationCount = newValue }
        get { return loadQueue.maxConcurrentOperationCount }
    }
    
    public var currentLoadCount: Int {
        return loadQueue.operationCount
    }
    
    /// The timeout value (in seconds) for the load operation.
    public var loadTimeout: TimeInterval = 15.0
    
    public var isSuspended: Bool {
        get { return loadQueue.isSuspended }
        set { loadQueue.isSuspended = newValue }
    }
    
    /// Changes load operations execution order.
    public var exectutionOrder: ExecutionOrder = .fifo
    
    private let loadQueue: OperationQueue
    private weak var lastAddedOperation: OP?
    
    private var assetOperations: [String: OP] = [:]
    private let operationsLock = UnfairLock()
    
    public init() {
        loadQueue = OperationQueue()
        loadQueue.maxConcurrentOperationCount = 6
        loadQueue.name = "com.meteor.MetadataLoader<\(OP.self)>.load"
    }
    
    deinit {
        loadQueue.cancelAllOperations()
    }
    
    /// Creates a async loader instance with a given Asset
    public func loadMetadata(with asset: A?, options: MetadataLoaderOptions = [], progressHandler: ProgressHandler?, completionHandler: CompletionHandler? = nil) -> MetadataLoadToken<OP>? {
        
        return add(progressHanlder: progressHandler, completionHandler: completionHandler, forAsset: asset) { [weak self] () -> OP in
            
            let operation = Provider.makeOperation(asset: asset, options: options)
            
            if let strongSelf = self {
                if strongSelf.exectutionOrder == .lifo {
                    // Emulate LIFO execution order by systematically adding new operations as last operation's dependency
                    strongSelf.lastAddedOperation?.addDependency(operation)
                    strongSelf.lastAddedOperation = operation
                }
            }
            
            return operation
        }
    }
    
    private func add(progressHanlder: ProgressHandler?, completionHandler: CompletionHandler?, forAsset asset: A?, createClosure: @escaping (() -> OP)) -> MetadataLoadToken<OP>? {
        
        guard let asset = asset else {
            completionHandler?(nil, nil, false)
            return nil
        }
        
        let key = asset.identifier
        
        operationsLock.lock()
        var operation: OP? = assetOperations[key]
        if operation == nil {
            let op = createClosure()
            op.completionBlock = { [weak self] in
                guard let strongSelf = self else { return }
                strongSelf.operationsLock.lock()
                strongSelf.assetOperations.removeValue(forKey: key)
                strongSelf.operationsLock.unlock()
            }
            assetOperations[key] = op
            loadQueue.addOperation(op)
            operation = op
        }
        operationsLock.unlock()
        
        let downloadOperationCancelToken = operation?.addHandlers(progressHandler: progressHanlder, completionHander: completionHandler)
        
        let token = MetadataLoadToken<OP>()
        token.loadOperation = operation
        token.asset = asset
        token.loadOperationCancelToken = downloadOperationCancelToken
        
        return token
    }
    
    /// Cancels a load that was previously queued using -loadMetadataWithAsset:options:progressHandler:completionHandler:
    public func cancel(_ token: MetadataLoadToken<OP>?) {
        guard let tk = token, let key = tk.asset?.identifier else { return }
        operationsLock.lock()
        if let operation = assetOperations[key] {
            let canceled = operation.cancel(tk.loadOperationCancelToken)
            if canceled {
                assetOperations.removeValue(forKey: key)
            }
        }
        operationsLock.unlock()
    }
    
    /// Cancels all load operations in the queue
    public func cancelAllLoads() {
        loadQueue.cancelAllOperations()
    }
        
}
