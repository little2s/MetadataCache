//
//  KeyedPersistenceDirectory.swift
//
//
//  Created by yinglun on 2019/12/18.
//

import Foundation
import CommonCrypto

struct KeyedPersistenceDirectory {
    
    let url: URL
    
    private let fileManager: FileManager
    
    private init(url: URL) {
        self.url = url
        self.fileManager = FileManager()
    }
    
    init(name: String, directory: FileManager.SearchPathDirectory) {
        let directory = try! FileManager.default.url(for: directory, in: .userDomainMask, appropriateFor: nil, create: true)
        let url = directory.appendingPathComponent("com.meteor.metadata-cache.file").appendingPathComponent(KeyedPersistenceDirectory.md5Hash(for: name))
        self.init(url: url)
    }
    
    @inlinable
    func fileURL(for key: String) -> URL {
        let pathExtension = self.url.appendingPathComponent(key).pathExtension
        return self.url.appendingPathComponent(KeyedPersistenceDirectory.md5Hash(for: key)).appendingPathExtension(pathExtension)
    }
    
    func data(for key: String) -> Data? {
        let url = self.fileURL(for: key)
        if self.fileManager.fileExists(atPath: url.path) {
            return try? Data(contentsOf: url)
        }
        return nil
    }
    
    func save(data: Data, for key: String) throws {
        let url = self.fileURL(for: key)
        try data.write(to: url, options: .atomic)
    }
    
    func clear() {
        if self.fileManager.fileExists(atPath: self.url.path) {
            try? self.fileManager.removeItem(at: self.url)
        }
    }
    
    @inlinable
    internal static func md5Hash(for string: String) -> String {
        let length = Int(CC_MD5_DIGEST_LENGTH)
        let messageData = string.data(using:.utf8)!
        var digestData = Data(count: length)
        _ = digestData.withUnsafeMutableBytes { digestBytes -> UInt8 in
            messageData.withUnsafeBytes { messageBytes -> UInt8 in
                if let messageBytesBaseAddress = messageBytes.baseAddress, let digestBytesBlindMemory = digestBytes.bindMemory(to: UInt8.self).baseAddress {
                    let messageLength = CC_LONG(messageData.count)
                    CC_MD5(messageBytesBaseAddress, messageLength, digestBytesBlindMemory)
                }
                return 0
            }
        }
        return digestData.map({ String(format: "%02hhx", $0) }).joined()
    }


}
