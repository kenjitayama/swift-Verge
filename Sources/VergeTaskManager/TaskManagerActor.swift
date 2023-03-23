import Foundation

public protocol TaskKeyType {

}

/**
 
 ```swift
 enum MyRequestTask: TaskKeyType {}
 let key = TaskKey(MyRequestTask.self)
 ```
 
 */
public struct TaskKey: Hashable, Sendable {

  private struct TypedKey: Hashable, Sendable {

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.metatype == rhs.metatype
    }

    func hash(into hasher: inout Hasher) {
      hasher.combine(ObjectIdentifier(metatype))
    }

    let metatype: Any.Type

    init<T>(base: T.Type) {
      self.metatype = base
    }

  }

  private enum Node: Hashable, Sendable {
    case customString(String)
    case type(TypedKey)
  }

  private let node: Node

  public init<Key: TaskKeyType>(_ key: Key.Type) {
    self.node = .type(.init(base: Key.self))
  }

  public init(_ customString: String) {
    self.node = .customString(customString)
  }

  /// Make with a new unique identifier
  public static func distinct() -> Self {
    .init(UUID().uuidString)
  }

}

/**
 An actor that manages tasks by specified keys.
 It enqueues a given task into a separated queue by key.
 Consumers can specify how to handle the current task as dropping it or waiting for it. 
 */
public actor TaskManagerActor {

  public struct Configuration {

    public init() {

    }
  }
 
  public enum Mode: Sendable {
    /**
     Cancels the current running task then start a new task.
     */
    case dropCurrent
    /**
     Waits the current task finished then start a new task.
     */
    case waitInCurrent
  }

  // MARK: Lifecycle

  public init(configuration: Configuration = .init()) {
    self.configuration = configuration
  }

  deinit {
  }

  // MARK: Public

  public let configuration: Configuration

  /**
   Returns a Boolean value that indicates whether the task for given key is currently running.
   */
  public func isRunning(for key: TaskKey) async -> Bool {
    guard let queue = queues[key] else {
      return false
    }

    return await queue.hasTask
  }
  
  /// Registers an asynchronous operation
  ///
  /// Task's Error may be ``CancellationError``
  /// - Parameters:
  ///   - label: String value for debugging
  ///   - key: ``TaskKey`` value takes associated operations. It creates queues for each key.
  ///   - mode: Mode tells the queue how controls the given new operation. to run immediately with drop all current operation or wait all them.
  ///   - priority:
  ///   - action:
  /// - Returns: An Task to track the operation's completion.
  @discardableResult
  public func task<Return>(
    label: String = "",
    key: TaskKey,
    mode: Mode,
    priority: TaskPriority = .userInitiated,
    @_inheritActorContext _ action: @Sendable @escaping () async throws -> Return
  ) async -> Task<Return, Error> {
    
    let targetQueue = prepareQueue(for: key)
    
    switch mode {
    case .dropCurrent:
      return await targetQueue.batch {
        $0.cancelAllTasks()
        return $0.addTask(label: label, priority: priority, operation: action)
      }
    case .waitInCurrent:
      return await targetQueue.addTask(label: label, priority: priority, operation: action)
    }
    
  }

  public func taskDetached<Return>(
    label: String = "",
    key: TaskKey,
    mode: Mode,
    priority: TaskPriority = .userInitiated,
    _ action: @Sendable @escaping () async throws -> Return
  ) async -> Task<Return, Error> {
    await task(label: label, key: key, mode: mode, priority: priority, action)
  }
  
  private func prepareQueue(for key: TaskKey) -> TaskQueueActor {
    let targetQueue: TaskQueueActor
    
    if let currentQueue = queues[key] {
      targetQueue = currentQueue
    } else {
      let newQueue = TaskQueueActor()
      
      Task { [weak self] in
        await newQueue.waitUntilAllItemProcessed()
        await self?.batch {
          $0.queues.removeValue(forKey: key)
        }
      }

      queues[key] = newQueue
      targetQueue = newQueue
    }
    return targetQueue
  }
  
  public func batch(_ closure: (isolated TaskManagerActor) -> Void) {
    closure(self)
  }
  
  public func batch(_ closure: (isolated TaskManagerActor) async -> Void) async {
    await closure(self)
  }

  /**
   Cancells all tasks managed in this manager.
   */
  public func cancelAll() async {

    for queue in queues.values {
      await queue.cancelAllTasks()
    }

    queues.removeAll()
  }

  // MARK: Private
  
  private var queues: [TaskKey : TaskQueueActor] = [:]
  
}