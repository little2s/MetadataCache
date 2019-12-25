//
//  MetadataLoadOperation.swift
//
//
//  Created by yinglun on 2019/12/18.
//

import Foundation

public protocol MetadataLoadOperationProtocol {
    
    associatedtype A: Asset
    associatedtype M: Metadata
            
    func addHandlers(progressHandler: ((Double) -> Void)?, completionHander: ((M?, Error?, Bool) -> Void)?) -> Any?
    
    func cancel(_ token: Any?) -> Bool
    
}

public typealias MetadataLoadOperation = Operation & MetadataLoadOperationProtocol

public protocol MetadataLoadOperationProvider {
    
    associatedtype OP: MetadataLoadOperation
    
    static func makeOperation(asset: OP.A?, options: MetadataLoaderOptions) -> OP
    
}
