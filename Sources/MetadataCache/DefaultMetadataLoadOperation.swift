//
//  DefaultMetadataLoadOperation.swift
//  
//
//  Created by yinglun on 2019/12/18.
//

import Foundation

public final class DefaultMetadataLoadOperation<A, M>: MetadataLoadOperation where A: Asset, M: Metadata {

    public let asset: A?
    public let options: MetadataLoaderOptions
    private let loadClosure: (A?) -> (M?, Error?)
    
    private struct Callback {
        var progress: ((Double) -> Void)??
        var completion: ((M?, Error?, Bool) -> Void)?
    }
    
    private var callbacks: [UUID: Callback] = [:]
    private let callbacksLock = UnfairLock()
    
    public init(asset: A?, options: MetadataLoaderOptions, loadClosure: @escaping (A?) -> (M?, Error?)) {
        self.asset = asset
        self.options = options
        self.loadClosure = loadClosure
        super.init()
    }
    
    public func addHandlers(progressHandler: ((Double) -> Void)?, completionHander: ((M?, Error?, Bool) -> Void)?) -> Any? {
        let token = UUID()
        let cb = Callback(progress: progressHandler, completion: completionHander)
        callbacksLock.lock()
        callbacks[token] = cb
        callbacksLock.unlock()
        return token
    }
    
    public func cancel(_ token: Any?) -> Bool {
        if let tk = token as? UUID {
            callbacksLock.lock()
            callbacks.removeValue(forKey: tk)
            callbacksLock.unlock()
            return true
        } else {
            return false
        }
    }
    
    public override func main() {
        if self.isCancelled {
            return
        }
        let r = loadClosure(self.asset)
        if !self.isCancelled {
            var cbList: [Callback] = []
            callbacksLock.lock()
            cbList = Array(callbacks.values)
            callbacksLock.unlock()
            guard !cbList.isEmpty else { return }
            DispatchQueue.main.async {
                cbList.forEach { $0.completion?(r.0, r.1, r.1 != nil) }
            }
        }
    }
    
}
