import 'package:meta/meta.dart';

import 'task.dart';

class TaskManager {
  final List<Task> _workingTasks = [];

  /// 判断是否有 taskID 对应的 Task 正在运行
  bool hasTask(String taskID) {
    return _workingTasks.any((task) => task.taskID() == taskID);
  }

  /// 添加一个 [Task]
  ///
  /// 被添加的 [task] 会被立即执行 [createTask]
  /// task 执行完就会从管理器中移除
  @mustCallSuper
  Future<void> addTask(Task task) async {
    _workingTasks.add(task);
    try {
      await task.preStart();
      final taskFuture = task.createTask();
      await task.postStart();

      final result = await taskFuture;
      await removeTask(task);
      await task.postReceive(result);
    } catch (error) {
      if (task.showRetry(error)) {
        await task.postError(error, complete: false);
        await restartTask(task);
      } else {
        await removeTask(task);
        await task.postError(error, complete: true);
      }
    }
  }

  @mustCallSuper
  Future<void> removeTask(Task task) async {
    _workingTasks.remove(task);
  }

  @mustCallSuper
  Future<void> restartTask(Task task) async {
    try {
      await task.preRestart();
      final taskFuture = task.createTask();
      await task.postRestart();

      final result = await taskFuture;
      await removeTask(task);
      await task.postReceive(result);
    } catch (error) {
      if (task.showRetry(error)) {
        await task.postError(error, complete: false);
        await restartTask(task);
      } else {
        await removeTask(task);
        await task.postError(error, complete: true);
      }
    }
  }

  /// 返回当前运行中的 [Task]
  List<Task<dynamic>> getTasks() {
    return _workingTasks;
  }

  /// 查找类型符合 [T] 的 [Task]
  List<T> getTasksByType<T extends Task<dynamic>>() {
    return _workingTasks.whereType<T>().toList();
  }
}
