//
//  Metadata.swift
//
//
//  Created by yinglun on 2019/12/18.
//

import Foundation

public protocol Asset {
    
    var identifier: String { get }
    
}

public protocol Metadata {
    
    static func decodeFromData(_ data: Data) throws -> Self
    
    func encodeToData() throws -> Data
    
}

public extension Metadata where Self: Codable {
    
    static func decodeFromData(_ data: Data) throws -> Self {
        return try JSONDecoder().decode(Self.self, from: data)
    }
    
    func encodeToData() throws -> Data {
        return try JSONEncoder().encode(self)
    }
    
}
