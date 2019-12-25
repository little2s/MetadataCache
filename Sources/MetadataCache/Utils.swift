//
//  Utils.swift
//
//
//  Created by yinglun on 2019/12/18.
//

import Foundation

final class UnfairLock {
    
    private var _lock = os_unfair_lock()
    
    func lock() {
        os_unfair_lock_lock(&_lock)
    }
    
    func unlock() {
        os_unfair_lock_unlock(&_lock)
    }
    
}

extension DispatchQueue {
    
    func safeAsync(_ closure: @escaping () -> Void) {
        if self === DispatchQueue.main && Thread.isMainThread {
            closure()
        } else {
            async { closure() }
        }
    }
    
}
