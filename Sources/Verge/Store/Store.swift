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
import os.log
import VergeTaskManager

@_implementationOnly import Atomics

#if canImport(Combine)
import Combine
#endif

/// A protocol that indicates itself is a reference-type and can convert to concrete Store type.
public protocol StoreType<State>: AnyObject {
  associatedtype State: Equatable
  associatedtype Activity = Never
  
  func asStore() -> Store<State, Activity>
  
  var primitiveState: State { get }
  var state: Changes<State> { get }
}

public typealias NoActivityStoreBase<State: Equatable> = Store<State, Never>

private let sanitizerQueue = DispatchQueue.init(label: "org.vergegroup.verge.sanitizer")

public enum _StoreEvent<State: Equatable, Activity> {
  
  public enum StateEvent {
    case willUpdate
    case didUpdate(Changes<State>)
  }
  
  case state(StateEvent)
  case activity(Activity)
}

/// An object that retains a latest state value and receives mutations that modify itself state.
/// Those updates would be shared all of the subscribers these are sink(s), Derived(s)
///
/// You may create subclass of VergeDefaultStore
/// ```
/// final class MyStore: Store<MyState> {
///   init() {
///     super.init(initialState: .init(), logger: nil)
///   }
/// }
/// ```
/// You may use also `StoreWrapperType` to define State and Activity as inner types.
///
open class Store<State: Equatable, Activity>: EventEmitter<_StoreEvent<State, Activity>>, ObservableObject, CustomReflectable, StoreType, DispatcherType, @unchecked Sendable {

  public var scope: WritableKeyPath<State, State> = \State.self
          
  private let tracker = VergeConcurrency.SynchronizationTracker()
  
  /// A name of the store.
  /// Specified or generated automatically from file and line.
  public let name: String
  
  public let logger: StoreLogger?
  
  public let sanitizer: RuntimeSanitizer
  /// A Publisher to compatible SwiftUI
  public let objectWillChange: ObservableObjectPublisher = .init()
  
  public var valuePublisher: some Combine.Publisher<Changes<State>, Never> {
    return _valueSubject
  }
    
  private var middlewares: [AnyStoreMiddleware<State>] = []
  
  private let externalOperation: @Sendable (inout InoutRef<State>, Changes<State>) -> Void
  
  private var nonatomicValue: Changes<State>
  
  private let _lock: StoreOperation
      
  private let _valueSubject: CurrentValueSubject<Changes<State>, Never>

  /**
   Holds subscriptions for sink State and Activity to finish them with its store life-cycle.
   */
  private let storeLifeCycleCancellable: VergeAnyCancellable = .init()

  open var keepsAliveForSubscribers: Bool { false }

  private let wasInvalidated = Atomics.ManagedAtomic(false)

  // MARK: - Deinit
  
  deinit {
    invalidate()
  }


  // MARK: - Task
  
  public let taskManager: TaskManagerActor = .init()
      
  // MARK: - Initializers
  
  /// An initializer
  /// - Parameters:
  ///   - initialState: A state instance that will be modified by the first commit.
  ///   - backingStorageRecursiveLock: A lock instance for mutual exclusion.
  ///   - logger: You can also use `DefaultLogger.shared`.
  public nonisolated init(
    name: String? = nil,
    initialState: State,
    storeOperation: StoreOperation = .atomic,
    logger: StoreLogger? = nil,
    sanitizer: RuntimeSanitizer? = nil,
    _ file: StaticString = #file,
    _ line: UInt = #line
  ) {
    
    self.nonatomicValue = .init(old: nil, new: initialState)
    self._lock = storeOperation
    
    // TODO: copying value
    self._valueSubject = .init(nonatomicValue)
    
    self.logger = logger
    self.sanitizer = sanitizer ?? RuntimeSanitizer.global
    self.name = name ?? "\(file):\(line)"
    self.externalOperation = { @Sendable _, _ in }
    
  }
  
  public nonisolated init(
    name: String? = nil,
    initialState: State,
    storeOperation: StoreOperation = .atomic,
    logger: StoreLogger? = nil,
    sanitizer: RuntimeSanitizer? = nil,
    _ file: StaticString = #file,
    _ line: UInt = #line
  ) where State : StateType {
    
    // making reduced state
    var _initialState = initialState
    var inoutRef = InoutRef<State>.init(&_initialState)
    State.reduce(modifying: &inoutRef, current: .init(old: nil, new: initialState))
    let reduced = inoutRef.wrapped
    
    self.nonatomicValue = .init(old: nil, new: reduced)
    self._lock = storeOperation
    // TODO: copying value
    self._valueSubject = .init(nonatomicValue)
    
    self.logger = logger
    self.sanitizer = sanitizer ?? RuntimeSanitizer.global
    self.name = name ?? "\(file):\(line)"
    self.externalOperation = { @Sendable inoutRef, state in
      let intermediate = state.makeNextChanges(
        with: inoutRef.wrapped,
        from: inoutRef.traces,
        modification: inoutRef.modification ?? .indeterminate,
        transaction: .init()
      )
      State.reduce(modifying: &inoutRef, current: intermediate)
    }
    
  }

  @_spi(Internal)
  public final override func receiveEvent(_ event: _StoreEvent<State, Activity>) {
    
    switch event {
    case .state(let stateEvent):
      switch stateEvent {
      case .willUpdate:
        if Thread.isMainThread {
          objectWillChange.send()
        } else {
          DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
          }
        }
      case .didUpdate(let state):
        _valueSubject.send(state)
        stateDidUpdate(newState: state)
      }
    case .activity:
      break
    }
  }

  open func stateDidUpdate(newState: Changes<State>) {

  }

  final func invalidate() {
    guard wasInvalidated.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged else {
      // already invalidated
      return
    }
    performInvalidation()
  }

  func performInvalidation() {

    storeLifeCycleCancellable.cancel()

    Task { [taskManager, _valueSubject] in
      // send completion in hop as Combine is using unfair lock (non-recursive). Avoid crash.
      // It happens if the stream ratains this store, canceled that stream triggers this deinit operation.
      // that deinit operation will be inside of locking session.
      _valueSubject.send(completion: .finished)
      await taskManager.cancelAll()
    }
  }
}

// MARK: - Typealias
extension Store {
  
  public typealias Scope = State
  public typealias Dispatcher = DispatcherBase<State, Activity>
  public typealias ScopedDispatcher<Scope: Equatable> = ScopedDispatcherBase<State, Activity, Scope>
  public typealias Value = State
}

// MARK: - Computed Properties
extension Store {
  
  public var store: Store<State, Activity> { self }
  
  public var objectDidChange: AnyPublisher<Changes<State>, Never> {
    valuePublisher.dropFirst().eraseToAnyPublisher()
  }

  
  /// A current state.
  ///
  /// It causes locking and unlocking with a bit cost.
  /// It may cause blocking if any other is doing mutation or reading.
  public var primitiveState: State {
    state.primitive
  }
  
  /// Returns a current state with thread-safety.
  ///
  /// It causes locking and unlocking with a bit cost.
  /// It may cause blocking if any other is doing mutation or reading.
  public var state: Changes<State> {
    _lock.lock()
    defer {
      _lock.unlock()
    }
    return nonatomicValue
  }
  
  /// A current changes state.
  @available(*, deprecated, renamed: "state")
  public var changes: Changes<State> {
    state
  }
 
}

// MARK: - Convenience Initializers
extension Store {

  
  /// An initializer for preventing using the refence type as a state.
  @available(*, deprecated, message: "Using the reference type for the state is restricted. it must be a value type to run correctly.")
  public convenience init(
    name: String? = nil,
    initialState: State,
    storeOperation: StoreOperation = .atomic,
    logger: StoreLogger? = nil,
    _ file: StaticString = #file,
    _ line: UInt = #line
  ) where State : AnyObject {
    
    preconditionFailure("Using the reference type for the state is restricted. it must be a value type to run correctly.")
    
  }

}

// MARK: - Middleware
extension Store {
     
  /// Registers a middleware.
  /// MIddleware can execute additional operations unified with mutations.
  ///
  public func add(middleware: some StoreMiddlewareType<State>) {
    // use lock
    lock()
    defer {
      unlock()
    }
    middlewares.append(.init(modify: middleware.modify))
  }
}

extension Store {
    
  // MARK: - CustomReflectable
  public var customMirror: Mirror {
    return Mirror(
      self,
      children: KeyValuePairs.init(
        dictionaryLiteral:
          ("stateVersion", state.version),
        ("middlewares", middlewares)
      ),
      displayStyle: .class
    )
  }
  
  @inline(__always)
  public func asStore() -> Store<State, Activity> {
    self
  }

  /**
   Adds an asynchronous task to perform.
   
   Use this function to perform an asynchronous task with a lifetime that matches that of this store.
   If this store is deallocated ealier than the given task finished, that asynchronous task will be cancelled.
   
   Carefully use this function - If the task retains this store, it will continue to live until the task is finished.

   - Parameters:
     - key:
     - mode:
     - priority:
     - action
   - Returns: A Task for tracking given async operation's completion.
   */
  @discardableResult
  public func task<Return>(
    key: VergeTaskManager.TaskKey = .distinct(),
    mode: VergeTaskManager.TaskManagerActor.Mode = .dropCurrent,
    priority: TaskPriority = .userInitiated,
    @_inheritActorContext _ action: @Sendable @escaping () async throws -> Return
  ) -> Task<Return, Error> {

    Task {
      try await taskManager.task(key: key, mode: mode, priority: priority, action)
        .value
    }
    
  }

  /**
   Adds an asynchronous task to perform.

   Use this function to perform an asynchronous task with a lifetime that matches that of this store.
   If this store is deallocated ealier than the given task finished, that asynchronous task will be cancelled.

   Carefully use this function - If the task retains this store, it will continue to live until the task is finished.

   - Parameters:
   - key:
   - mode:
   - priority:
   - action
   - Returns: A Task for tracking given async operation's completion.
   */
  @discardableResult
  public func taskDetached<Return>(
    key: VergeTaskManager.TaskKey = .distinct(),
    mode: VergeTaskManager.TaskManagerActor.Mode = .dropCurrent,
    priority: TaskPriority = .userInitiated,
    _ action: @Sendable @escaping () async throws -> Return
  ) -> Task<Return, Error> {

    Task {
      try await taskManager.taskDetached(key: key, mode: mode, priority: priority, action)
        .value
    }

  }

  // MARK: - Internal
  
  /// Receives mutation
  ///
  /// - Parameters:
  ///   - mutation: (`inout` attributes to prevent escaping `Inout<State>` inside the closure.)
  @inline(__always)
  func _receive<Result>(
    mutation: (inout InoutRef<State>) throws -> Result
  ) rethrows -> Result {
    
    let signpost = VergeSignpostTransaction("Store.commit")
    defer {
      signpost.end()
    }
    
    let warnings: Set<VergeConcurrency.SynchronizationTracker.Warning>
    if RuntimeSanitizer.global.isRecursivelyCommitDetectionEnabled {
      warnings = tracker.register()
    } else {
      warnings = .init()
    }
    
    defer {
      if RuntimeSanitizer.global.isRecursivelyCommitDetectionEnabled {
        tracker.unregister()
      }
    }
    
    var valueFromMutation: Result!
    var elapsed: CFTimeInterval = 0
    var commitLog: CommitLog?
    
    let __sanitizer__ = sanitizer
    
    /** a ciritical session */
    try _update { (state) -> UpdateResult in
      
      let startedTime = CFAbsoluteTimeGetCurrent()
      defer {
        elapsed = CFAbsoluteTimeGetCurrent() - startedTime
      }
      
      var current = state.primitive
      
      let updateResult = try withUnsafeMutablePointer(to: &current) { (stateMutablePointer) -> UpdateResult in
        
        var inoutRef = InoutRef<State>.init(stateMutablePointer)
        
        let result = try mutation(&inoutRef)
        valueFromMutation = result
        
        /**
         Step-1:
         Checks if the state has been modified
         */
        guard inoutRef.nonatomic_hasModified else {
          // No emits update event
          return .nothingUpdates
        }
        
        /**
         Step-2:
         Reduce modifying state with externalOperation
         */
        
        externalOperation(&inoutRef, state)
        
        /**
         Step-3
         Applying by middlewares
         */
        self.middlewares.forEach { middleware in
          
          let intermediate = state.makeNextChanges(
            with: stateMutablePointer.pointee,
            from: inoutRef.traces,
            modification: inoutRef.modification ?? .indeterminate,
            transaction: inoutRef._transaction
          )
          middleware.modify(modifyingState: &inoutRef, current: intermediate)
        }
        
        /**
         Make a new state
         */
        state = state.makeNextChanges(
          with: stateMutablePointer.pointee,
          from: inoutRef.traces,
          modification: inoutRef.modification ?? .indeterminate,
          transaction: inoutRef._transaction
        )
        
        if __sanitizer__.isRecursivelyCommitDetectionEnabled {
          if warnings.contains(.reentrancyAnomaly) {
            os_log(
              """
⚠️ [Verge Error] Detected another commit recursively from the commit.
This breaks the order of the states that receiving in the sink.

You might be doing commit inside the sink at the same Store.
In this case, Using dispatch solve this issue.

Mutation: (%@)
""",
              log: VergeOSLogs.debugLog,
              type: .error,
              String(describing: inoutRef.traces)
            )
            __sanitizer__.onDidFindRuntimeError(.recursiveleyCommit(storeName: name, traces: inoutRef.traces))
          }
        }
        
        commitLog = CommitLog(storeName: self.name, traces: inoutRef.traces, time: elapsed)
        
        return .updated
      }
      
      return updateResult
      
    }
    
    if let logger = logger, let _commitLog = commitLog {
      logger.didCommit(log: _commitLog, sender: self)
    }
    
    return valueFromMutation
  }
  
  @inline(__always)
  func _send(
    activity: Activity,
    trace: ActivityTrace
  ) {
    
    accept(.activity(activity))
    
    let log = ActivityLog(storeName: self.name, trace: trace)
    logger?.didSendActivity(log: log, sender: self)
  }

  func _mainActor_sinkState(
    keepsAliveSource: Bool? = nil,
    dropsFirst: Bool = false,
    queue: MainActorTargetQueue,
    receive: @escaping @MainActor (Changes<State>) -> Void
  ) -> StoreSubscription {
    return _primitive_sinkState(queue: Queues.MainActor(queue), receive: receive)
  }
  
  func _primitive_sinkState(
    dropsFirst: Bool = false,
    queue: some TargetQueueType,
    receive: @escaping (Changes<State>) -> Void
  ) -> StoreSubscription {
    
    let executor = queue.execute
    
    var latestStateWrapper: Changes<State>? = nil
    
    let __sanitizer__ = sanitizer
    
    let lock = VergeConcurrency.UnfairLock()
    
    /// Firstly, it registers a closure to make sure that it receives all of the updates, even updates inside the first call.
    /// To get recursive updates that comes from first call receive closure.
    let cancellable = _sinkStateEvent { (event) in
      switch event {
      case .willUpdate:
        break
      case .didUpdate(let receivedState):
        
        executor {
          
          lock.lock()
          
          var resolvedReceivedState = receivedState
          
          // To escaping from critical issue
          if let latestState = latestStateWrapper {
            if latestState.version <= receivedState.version {
              /*
               No issues case:
               It has received newer version than previous version
               */
              latestStateWrapper = receivedState
            } else {
              
              /*
               Serious problem case:
               Received an older version than the state received before.
               To recover this case, send latest version state with dropping previous value in order to make `ifChanged` returns always true.
               */
              resolvedReceivedState = latestState.droppedPrevious()
              
              if __sanitizer__.isSanitizerStateReceivingByCorrectOrder {
                
                sanitizerQueue.async {
                  __sanitizer__.onDidFindRuntimeError(
                    .recoveredStateFromReceivingOlderVersion(
                      latestState: latestState,
                      receivedState: receivedState
                    )
                  )
                  
                  os_log(
                    """
⚠️ [Verge Error] Received older version(%d) value rather than latest received version(%d).

The root cause might be from the following things:
- Committed concurrently from multiple threads.

To solve, make sure to commit in series, for example using DispatchQueue.

Verge can't use a lock to process serially because the dead-lock will happen in some of the cases.
RxSwift's BehaviorSubject takes the same deal.

Regarding: Extra commit was dispatched inside sink synchronously
This issue has been fixed by https://github.com/VergeGroup/Verge/pull/222
---

Received older version (%d): (%@)

Latest Version (%d): (%@)

===
""",
                    log: VergeOSLogs.debugLog,
                    type: .error,
                    receivedState.version,
                    latestState.version,
                    receivedState.version,
                    String(describing: receivedState.traces),
                    latestState.version,
                    String(describing: latestState.traces)
                  )
                }
              }
            }
            
          } else {
            // first item
            latestStateWrapper = receivedState
          }
          
          lock.unlock()
          
          receive(resolvedReceivedState)
        }        
      }
    }
    
    if !dropsFirst {
      
      let value = state.droppedPrevious()
      
      executor {
        lock.lock()
        latestStateWrapper = value
        lock.unlock()
        // this closure might contains some mutations.
        // It depends outside usages.
        receive(value)
      }
    }

    if keepsAliveForSubscribers {
      return .init(cancellable, storeCancellable: storeLifeCycleCancellable)
        .associate(store: self) // while subscribing its Store will be alive
    } else {
      return .init(cancellable, storeCancellable: storeLifeCycleCancellable)
    }
    
  }

  func _mainActor_scan_sinkState<Accumulate>(
    scan: Scan<Changes<State>, Accumulate>,
    dropsFirst: Bool = false,
    queue: MainActorTargetQueue,
    receive: @escaping @MainActor (Changes<State>, Accumulate) -> Void
  ) -> StoreSubscription {

    _mainActor_sinkState(dropsFirst: dropsFirst, queue: queue) { (changes) in

      let accumulate = scan.accumulate(changes)
      receive(changes, accumulate)
    }

  }
  
  func _primitive_scan_sinkState<Accumulate>(
    scan: Scan<Changes<State>, Accumulate>,
    dropsFirst: Bool = false,
    queue: some TargetQueueType,
    receive: @escaping (Changes<State>, Accumulate) -> Void
  ) -> StoreSubscription {
    
    _primitive_sinkState(dropsFirst: dropsFirst, queue: queue) { (changes) in
      
      let accumulate = scan.accumulate(changes)
      receive(changes, accumulate)
    }
    
  }

  func _mainActor_sinkActivity(
    queue: MainActorTargetQueue,
    receive: @escaping @MainActor (Activity) -> Void
  ) -> StoreSubscription {
    return _primitive_sinkActivity(queue: Queues.MainActor(queue), receive: receive)
  }

  func _primitive_sinkActivity(
    queue: some TargetQueueType,
    receive: @escaping (Activity) -> Void
  ) -> StoreSubscription {

    let execute = queue.execute
    let cancellable = self._sinkActivityEvent { activity in
      execute {
        receive(activity)
      }
    }
    
    return .init(cancellable, storeCancellable: storeLifeCycleCancellable)

  }

}

// MARK: - Storage Implementation
extension Store {
    
  public func lock() {
    _lock.lock()
  }
  
  public func unlock() {
    _lock.unlock()
  }
  
  final func _sinkStateEvent(subscriber: @escaping (_StoreEvent<State, Activity>.StateEvent) -> Void) -> EventEmitterCancellable {
    addEventHandler { event in
      guard case .state(let stateEvent) = event else { return }
      subscriber(stateEvent)
    }
  }
  
  final func _sinkActivityEvent(subscriber: @escaping (Activity) -> Void) -> EventEmitterCancellable {
    addEventHandler { event in
      guard case .activity(let activity) = event else { return }
      subscriber(activity)
    }
  }
    
  enum UpdateResult {
    case updated
    case nothingUpdates
  }
  
  @inline(__always)
  final func _update(_ update: (inout Changes<State>) throws -> UpdateResult) rethrows {
    
    let signpost = VergeSignpostTransaction("Storage.update")
    defer {
      signpost.end()
    }
    
    lock()
    do {
      
      let result = try update(&nonatomicValue)
      
      switch result {
      case .nothingUpdates:
        unlock()
      case .updated:
        let afterValue = nonatomicValue
        
        /**
         Unlocks lock before emitting event to avoid dead-locking.
         But it causes cracking the order of event.
         SeeAlso: testOrderOfEvents
         */
        unlock()
        
        // it's not actual `will` 👨🏻❓
        accept(.state(.willUpdate))
        accept(.state(.didUpdate(afterValue)))
        
      }
      
    } catch {
      unlock()
      throw error
    }
  }
  
}

extension Store {
  
  /// [Experimental]
  public func stateStream() -> AsyncStream<Changes<State>> {
    return .init(Changes<State>.self, bufferingPolicy: .unbounded) { continuation in
      
      let subscription = self.sinkState(queue: .passthrough) { state in
        continuation.yield(state)
      }
      
      continuation.onTermination = { termination in
        subscription.cancel()
      }
      
    }
  }
  
}
