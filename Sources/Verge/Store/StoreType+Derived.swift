//
// Copyright (c) 2020 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
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

import class Foundation.NSString

extension StoreType {

  /// Creates an instance of Derived
  private func _makeDerived<NewState>(
    _ memoizeMap: MemoizeMap<Changes<State>, NewState>,
    queue: TargetQueue
  ) -> Derived<NewState> {

    vergeSignpostEvent("Store.derived.new", label: "\(type(of: State.self)) -> \(type(of: NewState.self))")
    let derived = Derived<NewState>(
      get: memoizeMap,
      set: { _ in

      },
      initialUpstreamState: asStore().state,
      subscribeUpstreamState: { callback in
        asStore().sinkState(dropsFirst: true, queue: queue, receive: callback)
      },
      retainsUpstream: nil
    )
    return derived
  }

  /// Returns a Dervived object with making
  ///
  /// The returned instance might be a cached object which might be already subscribed by others.
  /// Which means it helps to be better performance in creating the same derived objects.
  ///
  /// - Complexity: 💡 It's better to set `dropsOutput` predicate.
  /// - Parameter
  ///   - memoizeMap:
  ///   - dropsOutput: Predicate to drops object if found a duplicated output
  /// - Returns: Derived object that cached depends on the specified parameters
  public func derived<NewState>(
    _ memoizeMap: MemoizeMap<Changes<State>, NewState>,
    dropsOutput: ((Changes<NewState>) -> Bool)? = nil,
    queue: TargetQueue = .passthrough
  ) -> Derived<NewState> {

    let derived = asStore().derivedCache2.withValue { cache -> Derived<NewState> in

      let identifier = "\(memoizeMap.identifier)\(ObjectIdentifier(queue))" as NSString

      guard let cached = cache.object(forKey: identifier) as? Derived<NewState> else {
        let instance = _makeDerived(memoizeMap, queue: queue)
        cache.setObject(instance, forKey: identifier)
        return instance
      }

      vergeSignpostEvent("Store.derived.reuse", label: "\(type(of: State.self)) -> \(type(of: NewState.self))")

      return cached

    }

    if let dropsOutput = dropsOutput {
      return derived.removeDuplicates(by: dropsOutput)
    } else {
      return derived
    }

  }

  /// Returns a Dervived object with making
  ///
  /// The returned instance might be a cached object which might be already subscribed by others.
  /// Which means it helps to be better performance in creating the same derived objects.
  ///
  /// - Complexity: ✅ Drops duplicated the output with Equatable comparison.
  ///
  /// - Parameter memoizeMap:
  /// - Returns: Derived object that cached depends on the specified parameters
  public func derived<NewState: Equatable>(
    _ memoizeMap: MemoizeMap<Changes<State>, NewState>,
    queue: TargetQueue = .passthrough
  ) -> Derived<NewState> {

    return asStore().derivedCache1.withValue { cache in

      let identifier = "\(memoizeMap.identifier)\(ObjectIdentifier(queue))" as NSString

      guard let cached = cache.object(forKey: identifier) as? Derived<NewState> else {
        let instance = _makeDerived(memoizeMap, queue: queue)
          .removeDuplicates(by: {
            $0.asChanges().noChanges(\.root)
          })
        cache.setObject(instance, forKey: identifier)
        return instance
      }

      vergeSignpostEvent("Store.derived.reuse", label: "\(type(of: State.self)) -> \(type(of: NewState.self))")

      return cached

    }

  }

  /// Returns Binding Derived object
  ///
  /// - Complexity: 💡 It's better to set `dropsOutput` predicate.
  /// - Parameters:
  ///   - name:
  ///   - get:
  ///   - dropsOutput: Predicate to drops object if found a duplicated output
  ///   - set:
  /// - Returns:
  public func binding<NewState>(
    _ name: String = "",
    _ file: StaticString = #file,
    _ function: StaticString = #function,
    _ line: UInt = #line,
    get: MemoizeMap<Changes<State>, NewState>,
    dropsOutput: @escaping (Changes<NewState>) -> Bool = { _ in false },
    set: @escaping (inout InoutRef<State>, NewState) -> Void,
    queue: TargetQueue = .passthrough
  ) -> BindingDerived<NewState> {

    let derived = BindingDerived<NewState>.init(
      get: get,
      set: { [weak self] state in
        self?.asStore().commit(name, file, function, line) {
          set(&$0, state)
        }
      },
      initialUpstreamState: asStore().state,
      subscribeUpstreamState: { callback in
        asStore().sinkState(
          dropsFirst: true,
          queue: queue,
          receive: callback
        )
      }, retainsUpstream: nil)

    derived.setDropsOutput(dropsOutput)

    return derived
  }

  /// Returns Binding Derived object
  ///
  /// - Complexity: ✅ Drops duplicated the output with Equatable comparison.
  /// - Parameters:
  ///   - name:
  ///   - get:
  ///   - set:
  /// - Returns:
  public func binding<NewState: Equatable>(
    _ name: String = "",
    _ file: StaticString = #file,
    _ function: StaticString = #function,
    _ line: UInt = #line,
    get: MemoizeMap<Changes<State>, NewState>,
    set: @escaping (inout InoutRef<State>, NewState) -> Void,
    queue: TargetQueue = .passthrough
  ) -> BindingDerived<NewState> {

    binding(
      name,
      file,
      function,
      line,
      get: get,
      dropsOutput: { $0.asChanges().noChanges(\.root) },
      set: set,
      queue: queue
    )
  }

}
