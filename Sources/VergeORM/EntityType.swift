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

public struct AnyEntityIdentifier: Hashable, Sendable {
  
  public typealias StringLiteralType = String

  public let value: PrimitiveIdentifier
  public init(_ value: PrimitiveIdentifier) {
    self.value = value
  }

}

public struct EntityIdentifier<Entity: EntityType> : Hashable, CustomStringConvertible, Sendable {
  
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.raw == rhs.raw
  }
  
  public func hash(into hasher: inout Hasher) {
    raw.hash(into: &hasher)
  }

  let any: AnyEntityIdentifier

  public let raw: Entity.EntityIDRawType

  public init(_ raw: Entity.EntityIDRawType) {
    self.raw = raw
    self.any = .init(raw._primitiveIdentifier)
  }
  
  init(_ anyIdentifier: AnyEntityIdentifier) {
    self.any = anyIdentifier
    self.raw = Entity.EntityIDRawType._restore(from: anyIdentifier.value)!
  }
  
  public var description: String {
    "<\(String(reflecting: Entity.self))>(\(raw))"
  }
}

/// A protocol describes object is an Entity.
///
/// EntityType has VergeTypedIdentifiable.
/// You might use IdentifiableEntityType instead, if you create SwiftUI app.
public protocol EntityType: Equatable, Sendable {

  associatedtype EntityIDRawType: _PrimitiveIdentifierConvertible

  static var entityName: EntityTableIdentifier { get }

  var entityID: EntityID { get }

  #if COCOAPODS
  typealias EntityTableKey = Verge.EntityTableKey<Self>
  #else
  typealias EntityTableKey = VergeORM.EntityTableKey<Self>
  #endif
  
  typealias EntityID = EntityIdentifier<Self>
}

extension EntityType {
    
  /// Returns EntityName from reflection
  ///
  /// - Warning:
  ///   Taking the name in runtime, it's not fast.
  ///   To be faster, override this property each your entities.
  public static var entityName: EntityTableIdentifier {
    .init(Self.self)
  }
    
  @available(*, deprecated, renamed: "EntityID")
  public typealias ID = EntityID
  
  @available(*, deprecated, renamed: "entityID")
  public var id: EntityID {
    _read { yield entityID }
  }

}

public struct EntityTableIdentifier: Hashable {

  public let name: String

  public init(_ rawName: String) {
    self.name = rawName
  }

  public init<T>(_ type: T.Type) {
    self.name = _typeName(T.self)
  }
}
