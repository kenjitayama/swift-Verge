//
// Copyright (c) 2020 muukii
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import Foundation

/// Ordered Collection based index storage
public struct SetIndex<Schema: EntitySchemaType, Entity: EntityType>: IndexType, Equatable {
  
  public typealias Element = Entity.EntityID
  
  // FIXME: To be faster filter, use BTree
  // To reduce cost of casting, use AnyHashable in _apply
  // If use [Entity.EntityID], .contains() will be expensive.
  @usableFromInline var backing: Set<AnyEntityIdentifier> = .init()
  
  public init() {
  }
  
  public mutating func _apply(removing: Set<AnyEntityIdentifier>, entityName: EntityTableIdentifier) {
    
    if Entity.entityName == entityName, !removing.isEmpty {
      backing.subtract(removing)
    }
        
  }
  
}

extension SetIndex {
  
  public func sorted(by areInIncreasingOrder: (Element, Element) throws -> Bool) rethrows -> [Element] {
    try backing.sorted(by: {
      try areInIncreasingOrder(Element($0), Element($1))
    }).map(Element.init)
  }
  
  public func map<T>(_ transform: (Element) throws -> T) rethrows -> [T] {
    try backing.map {
      try transform(.init($0))
    }
  }
  
  public func compactMap<ElementOfResult>(_ transform: (Element) throws -> ElementOfResult?) rethrows -> [ElementOfResult] {
    try backing.compactMap {
      try transform(.init($0))
    }
  }
  
  public mutating func insert(_ newMember: Element) -> (inserted: Bool, memberAfterInsert: Element) {
    let result = backing.insert(newMember.any)
    return (result.inserted, Element(result.memberAfterInsert))
  }
  
  public mutating func remove(_ member: Element) -> Element? {
    backing.remove(member.any).map(Element.init)
  }
  
  public mutating func removeAll(keepingCapacity keepCapacity: Bool = false) {
    backing.removeAll(keepingCapacity: keepCapacity)
  }
  
  public mutating func subtract(_ other: Set<Element>) {
    backing.subtract(other.map { $0.any })
  }
  
  public mutating func formUnion<S>(_ other: S) where Element == S.Element, S : Sequence {
    backing.formUnion(Set(other).map(\.any))
  }
}
