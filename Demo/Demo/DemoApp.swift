//
//  DemoApp.swift
//  Demo
//
//  Created by 刘子豪 on 2025/7/17.
//

import SwiftUI
import YYCache

@main
struct DemoApp: App {
    var body: some Scene {
        WindowGroup {
            Text("")
                .onAppear {
                    
                    let cache = YYCache(path: NSHomeDirectory().appending("/test"))
                    let t = cache?.object(forKey: "t")
                    print(t)
                    cache?.setObject("test".data(using: .utf8)!, forKey: "t")
                }
        }
    }
}
