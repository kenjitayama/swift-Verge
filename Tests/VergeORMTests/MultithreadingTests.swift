//
//  MultithreadingTests.swift
//  VergeORM
//
//  Created by muukii on 2020/03/17.
//  Copyright © 2020 muukii. All rights reserved.
//

import Foundation

import XCTest

import Verge
import VergeORM

class MultithreadingTests: XCTestCase {

  typealias _Store = Store<RootState, Never>
        
  func testUpdateFromThreads() {
    
    let store = _Store(initialState: RootState())
    
    let exp = expectation(description: "")
    
    let g = DispatchGroup()
    
    g.enter()
    for _ in 0..<200 {
            
      g.enter()
      DispatchQueue.global().async {
        store.commit { state in
          state.db.performBatchUpdates { (context) in
            
            let authors = (0..<1000).map { i in
              Author(rawID: "author.\(i)")
            }
            context.entities.author.insert(authors)
          }
        }
        print(store.state.db.entities.author.count)
        g.leave()
      }
    }
    g.leave()
    
    g.notify(queue: .main) {
      print(store.state.db.entities.author.count)
      exp.fulfill()
    }
    
    wait(for: [exp], timeout: 10)
                    
  }
  
  
  func testUpdateFromThreads2() {
    
    let store = _Store(initialState: RootState())
    
    measure(metrics: [XCTMemoryMetric(), XCTCPUMetric(), XCTClockMetric()]) {
      DispatchQueue.concurrentPerform(iterations: 1000) { (i) in
        store.commit { state in
          state.other.count += 1
        }
      }
    }
    
  }
  
  func testUpdateFromThreads3() {
    
    let store = _Store(initialState: RootState())

    var count = 0

    let sub = store.sinkState(dropsFirst: true, queue: .passthrough) { s in
      count += 1
    }

    measure {
      /**
       Checking if there is no conflicted processing.
       Performance is worse because performing critical-session concurrently.
       */
      DispatchQueue.concurrentPerform(iterations: 200) { (i) in
        store.commit { state in
          state.db.performBatchUpdates { (context) in
            
            let authors = (0..<40).map { i in
              Author(rawID: "author.\(i)")
            }
            context.entities.author.insert(authors)
          }
        }
      }
    }
    
    XCTAssertEqual(count, 200 * 10)

    withExtendedLifetime(sub) {}
    
  }
}
