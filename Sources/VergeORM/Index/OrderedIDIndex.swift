//
// Copyright (c) 2019 muukii
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
public struct OrderedIDIndex<Schema: EntitySchemaType, Entity: EntityType>: IndexType, Equatable {
  
  // FIXME: To be faster filter, use BTree
  // To reduce cost of casting, use AnyHashable in _apply
  // If use [Entity.EntityID], .contains() will be expensive.
  private var backing: [AnyEntityIdentifier] = []
  
  public init() {
  }
  
  public mutating func _apply(removing: Set<AnyEntityIdentifier>, entityName: EntityTableIdentifier) {
    
    if Entity.entityName == entityName, !removing.isEmpty {
      backing.removeAll { removing.contains($0) }
    }

  }
     
}

extension OrderedIDIndex: BidirectionalCollection, RandomAccessCollection, MutableCollection, RangeReplaceableCollection {
  
  public typealias Element = Entity.EntityID
  public typealias Index = Int
  public typealias SubSequence = ArraySlice<Entity.EntityID>
  
  public mutating func append(_ newElement: Entity.EntityID) {
    backing.append(newElement.any)
  }
  
  public subscript(position: Int) -> Entity.EntityID {
    get {
      .init(backing[position])
    }
    set {
      backing[position] = newValue.any
    }
  }

  public mutating func replaceSubrange<C>(_ subrange: Range<Int>, with newElements: C) where C : Collection, C.Element == Entity.EntityID {
    backing.replaceSubrange(subrange, with: newElements.map { $0.any })
  }

  public subscript(bounds: Range<Int>) -> ArraySlice<Entity.EntityID> {
    get {
      ArraySlice<Entity.EntityID>(AnySequence(backing[bounds].lazy.map { Entity.EntityID($0) }))
    }
    set {
      backing[bounds] = ArraySlice<AnyEntityIdentifier>(newValue.map { $0.any })
    }
  }
  
  public mutating func removeAll(keepingCapacity keepCapacity: Bool = false) {
    backing.removeAll(keepingCapacity: keepCapacity)
  }
  
  public var startIndex: Int {
    backing.startIndex
  }
  
  public var endIndex: Int {
    backing.endIndex
  }

}
