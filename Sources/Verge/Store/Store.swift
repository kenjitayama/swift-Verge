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

#if canImport(Combine)
import Combine
#endif

/// A protocol that indicates itself is a reference-type and can convert to concrete Store type.
public protocol StoreType: AnyObject {
  associatedtype State: Equatable
  associatedtype Activity = Never
  
  func asStore() -> Store<State, Activity>
  
  var primitiveState: State { get }
}

public typealias NoActivityStoreBase<State: Equatable> = Store<State, Never>

private let sanitizerQueue = DispatchQueue.init(label: "org.vergegroup.verge.sanitizer")

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
open class Store<State: Equatable, Activity>: _VergeObservableObjectBase, CustomReflectable, StoreType, DispatcherType, @unchecked Sendable {

  // MARK: - Typealias
  public typealias Scope = State
  public typealias Dispatcher = DispatcherBase<State, Activity>
  public typealias ScopedDispatcher<Scope: Equatable> = ScopedDispatcherBase<State, Activity, Scope>
  public typealias Value = State

  #if canImport(Combine)
  /// A Publisher to compatible SwiftUI
  @available(iOS 13, macOS 10.15, tvOS 13, watchOS 6, *)
  public final override var objectWillChange: ObservableObjectPublisher {
    _backingStorage.objectWillChange
  }
  #endif
    
  public var scope: WritableKeyPath<State, State> = \State.self
  
  public var store: Store<State, Activity> { self }
      
  /// A current state.
  ///
  /// It causes locking and unlocking with a bit cost.
  /// It may cause blocking if any other is doing mutation or reading.
  public var primitiveState: State {
    _backingStorage.value.primitive
  }

  /// Returns a current state with thread-safety.
  ///
  /// It causes locking and unlocking with a bit cost.
  /// It may cause blocking if any other is doing mutation or reading.
  public var state: Changes<State> {
    _backingStorage.value
  }
  
  /// A current changes state.
  @available(*, deprecated, renamed: "state")
  public var changes: Changes<State> {
    _backingStorage.value
  }
  
  public var __backingStorage: UnsafeMutableRawPointer {    
    Unmanaged.passUnretained(_backingStorage).toOpaque()
  }
  
  public var __activityEmitter: UnsafeMutableRawPointer {
    Unmanaged.passUnretained(_activityEmitter).toOpaque()
  }

  /// A backing storage that manages current state.
  /// You shouldn't access this directly unless special case.
  let _backingStorage: StateStorage<Changes<State>>
  let _activityEmitter: EventEmitter<Activity> = .init()
      
  private let tracker = VergeConcurrency.SynchronizationTracker()
  
  /// A name of the store.
  /// Specified or generated automatically from file and line.
  let name: String
  
  private var middlewares: [AnyStoreMiddleware<State>] = []
  
  public let logger: StoreLogger?
  public let sanitizer: RuntimeSanitizer
  
  private let externalOperation: @Sendable (inout InoutRef<State>, Changes<State>) -> Void
    
  // MARK: - Initializers
  
  /// An initializer
  /// - Parameters:
  ///   - initialState: A state instance that will be modified by the first commit.
  ///   - backingStorageRecursiveLock: A lock instance for mutual exclusion.
  ///   - logger: You can also use `DefaultLogger.shared`.
  public init(
    name: String? = nil,
    initialState: State,
    backingStorageRecursiveLock: VergeAnyRecursiveLock? = nil,
    logger: StoreLogger? = nil,
    sanitizer: RuntimeSanitizer? = nil,
    _ file: StaticString = #file,
    _ line: UInt = #line
  ) {

    self._backingStorage = .init(
      .init(old: nil, new: initialState),
      recursiveLock: backingStorageRecursiveLock ?? VergeConcurrency.RecursiveLock().asAny()
    )

    self.logger = logger
    self.sanitizer = sanitizer ?? RuntimeSanitizer.global
    self.name = name ?? "\(file):\(line)"
    self.externalOperation = { @Sendable _, _ in }

    super.init()
       
  }
  
  public init(
    name: String? = nil,
    initialState: State,
    backingStorageRecursiveLock: VergeAnyRecursiveLock? = nil,
    logger: StoreLogger? = nil,
    sanitizer: RuntimeSanitizer? = nil,
    _ file: StaticString = #file,
    _ line: UInt = #line
  ) where State : StateType {
    
    self._backingStorage = .init(
      .init(old: nil, new: initialState),
      recursiveLock: backingStorageRecursiveLock ?? VergeConcurrency.RecursiveLock().asAny()
    )
    
    self.logger = logger
    self.sanitizer = sanitizer ?? RuntimeSanitizer.global
    self.name = name ?? "\(file):\(line)"
    self.externalOperation = { @Sendable inoutRef, state in
      let intermediate = state.makeNextChanges(
        with: inoutRef.wrapped,
        from: inoutRef.traces,
        modification: inoutRef.modification ?? .indeterminate
      )
      State.reduce(modifying: &inoutRef, current: intermediate)
    }
    
    super.init()
  }
  
  /// An initializer for preventing using the refence type as a state.
  @available(*, deprecated, message: "Using the reference type for the state is restricted. it must be a value type to run correctly.")
  public convenience init(
    name: String? = nil,
    initialState: State,
    backingStorageRecursiveLock: VergeAnyRecursiveLock? = nil,
    logger: StoreLogger? = nil,
    _ file: StaticString = #file,
    _ line: UInt = #line
  ) where State : AnyObject {
    
    preconditionFailure("Using the reference type for the state is restricted. it must be a value type to run correctly.")
    
  }

  // MARK: - Middleware
  
  /// Registers a middleware.
  /// MIddleware can execute additional operations unified with mutations.
  ///
  public func add(middleware: some StoreMiddlewareType<State>) {
    // use lock
    _backingStorage.update { _ in
      middlewares.append(.init(modify: middleware.modify))
    }
  }

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

  // MARK: - Subscribings
  
  /// Subscribe the state changes
  ///
  /// First object always returns true from ifChanged / hasChanges / noChanges unless dropsFirst is true.
  ///
  /// - Parameters:
  ///   - dropsFirst: Drops the latest value on started. if true, receive closure will call from next state updated.
  ///   - queue: Specify a queue to receive changes object.
  /// - Returns: A subscriber that performs the provided closure upon receiving values.
  public func sinkState(
    dropsFirst: Bool = false,
    queue: TargetQueue,
    receive: @escaping (Changes<State>) -> Void
  ) -> VergeAnyCancellable {
    _sinkState(dropsFirst: dropsFirst, queue: queue, receive: receive)
  }
  
  /// Subscribe the state changes
  ///
  /// First object always returns true from ifChanged / hasChanges / noChanges unless dropsFirst is true.
  ///
  /// - Parameters:
  ///   - dropsFirst: Drops the latest value on started. if true, receive closure will call from next state updated.
  ///   - queue: Specify a queue to receive changes object.
  /// - Returns: A subscriber that performs the provided closure upon receiving values.
  public func sinkState(
    dropsFirst: Bool = false,
    queue: MainActorTargetQueue = .mainIsolated(),
    receive: @escaping @MainActor (Changes<State>) -> Void
  ) -> VergeAnyCancellable {
    _sinkState(dropsFirst: dropsFirst, queue: queue) { changes in
      thunkToMainActor {
        receive(changes)
      }
    }
  }

  /// Subscribe the state changes
  ///
  /// First object always returns true from ifChanged / hasChanges / noChanges unless dropsFirst is true.
  ///
  /// - Parameters:
  ///   - scan: Accumulates a specified type of value over receiving updates.
  ///   - dropsFirst: Drops the latest value on started. if true, receive closure will call from next state updated.
  ///   - queue: Specify a queue to receive changes object.
  /// - Returns: A subscriber that performs the provided closure upon receiving values.
  public func sinkState<Accumulate>(
    scan: Scan<Changes<State>, Accumulate>,
    dropsFirst: Bool = false,
    queue: TargetQueue,
    receive: @escaping (Changes<State>, Accumulate) -> Void
  ) -> VergeAnyCancellable {
    _sinkState(scan: scan, dropsFirst: dropsFirst, queue: queue, receive: receive)
  }
    
  /// Subscribe the state changes
  ///
  /// First object always returns true from ifChanged / hasChanges / noChanges unless dropsFirst is true.
  ///
  /// - Parameters:
  ///   - scan: Accumulates a specified type of value over receiving updates.
  ///   - dropsFirst: Drops the latest value on started. if true, receive closure will call from next state updated.
  ///   - queue: Specify a queue to receive changes object.
  /// - Returns: A subscriber that performs the provided closure upon receiving values.
  public func sinkState<Accumulate>(
    scan: Scan<Changes<State>, Accumulate>,
    dropsFirst: Bool = false,
    queue: MainActorTargetQueue = .mainIsolated(),
    receive: @escaping @MainActor (Changes<State>, Accumulate) -> Void
  ) -> VergeAnyCancellable {
    _sinkState(scan: scan, dropsFirst: dropsFirst, queue: queue) { changes, accumulated in
      thunkToMainActor {
        receive(changes, accumulated)
      }     
    }
  }
  
  private func _sinkActivity(
    queue: TargetQueueType,
    receive: @escaping (Activity) -> Void
  ) -> VergeAnyCancellable {
    
    let execute = queue.executor()
    let cancellable = _activityEmitter.add { (activity) in
      execute {
        receive(activity)
      }
    }
    return .init(cancellable)

  }
  
  /// Subscribe the activity
  ///
  /// - Returns: A subscriber that performs the provided closure upon receiving values.
  public func sinkActivity(
    queue: TargetQueue,
    receive: @escaping (Activity) -> Void
  ) -> VergeAnyCancellable {
    
   _sinkActivity(queue: queue, receive: receive)
    
  }

  /// Subscribe the activity
  ///
  /// - Returns: A subscriber that performs the provided closure upon receiving values.
  public func sinkActivity(
    queue: MainActorTargetQueue = .mainIsolated(),
    receive: @escaping @MainActor (Activity) -> Void
  ) -> VergeAnyCancellable {
   
    _sinkActivity(queue: queue) { activity in
      thunkToMainActor {
        receive(activity)
      }
    }
    
  }

  // MARK: - Task
  
  public let taskManager: TaskManager = .init()
  
  /**
   Adds an asynchronous task to perform.
   
   Use this function to perform an asynchronous task with a lifetime that matches that of this store.
   If this store is deallocated ealier than the given task finished, that asynchronous task will be cancelled.
   
   Carefully use this function - If the task retains this store, it will continue to live until the task is finished.
   */
  public func task(
    key: VergeTaskManager.TaskKey = .distinct(),
    mode: VergeTaskManager.TaskManager.Mode = .dropCurrent,
    priority: TaskPriority = .userInitiated,
    _ action: @Sendable @escaping () async -> Void
  ) {
    
    taskManager.task(key: key, mode: mode, priority: priority, action)
    
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
    try _backingStorage._update { (state) -> Storage<Changes<State>>.UpdateResult in
      
      let startedTime = CFAbsoluteTimeGetCurrent()
      defer {
        elapsed = CFAbsoluteTimeGetCurrent() - startedTime
      }
      
      var current = state.primitive
      
      let updateResult = try withUnsafeMutablePointer(to: &current) { (stateMutablePointer) -> Storage<Changes<State>>.UpdateResult in
        
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
            modification: inoutRef.modification ?? .indeterminate
          )
          middleware.modify(modifyingState: &inoutRef, current: intermediate)
        }
        
        /**
         Make a new state
         */
        state = state.makeNextChanges(
          with: stateMutablePointer.pointee,
          from: inoutRef.traces,
          modification: inoutRef.modification ?? .indeterminate
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
    
    _activityEmitter.accept(activity)
    
    let log = ActivityLog(storeName: self.name, trace: trace)
    logger?.didSendActivity(log: log, sender: self)
  }
  
  func _sinkState(
    dropsFirst: Bool = false,
    queue: TargetQueueType,
    receive: @escaping (Changes<State>) -> Void
  ) -> VergeAnyCancellable {
    
    let executor = queue.executor()
    
    var latestStateWrapper: Changes<State>? = nil
    
    let __sanitizer__ = sanitizer
    
    let lock = VergeConcurrency.UnfairLock()
    
    /// Firstly, it registers a closure to make sure that it receives all of the updates, even updates inside the first call.
    /// To get recursive updates that comes from first call receive closure.
    let cancellable = _backingStorage.sinkEvent { (event) in
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
        
      case .willDeinit:
        break
      }
    }
    
    if !dropsFirst {
      
      let value = _backingStorage.value.droppedPrevious()
      
      executor {
        lock.lock()
        latestStateWrapper = value
        lock.unlock()
        // this closure might contains some mutations.
        // It depends outside usages.
        receive(value)
      }
    }
    
    return .init(cancellable)
    
  }
    
  func _sinkState<Accumulate>(
    scan: Scan<Changes<State>, Accumulate>,
    dropsFirst: Bool = false,
    queue: TargetQueueType,
    receive: @escaping (Changes<State>, Accumulate) -> Void
  ) -> VergeAnyCancellable {
    
    _sinkState(dropsFirst: dropsFirst, queue: queue) { (changes) in
      
      let accumulate = scan.accumulate(changes)
      receive(changes, accumulate)
    }
    
  }
      
}



