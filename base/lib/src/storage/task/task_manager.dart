import 'package:meta/meta.dart';

import 'task.dart';

class TaskManager {
  final List<Task> workingTasks = [];

  /// 添加一个 [Task]
  ///
  /// 被添加的 [task] 会被立即执行 [createTask]
  @mustCallSuper
  Future<void> addTask(Task task) async {
    try {
      await task.preStart();
      workingTasks.add(task);
      final taskFuture = task.createTask();
      await task.postStart();

      final result = await taskFuture;
      await task.postReceive(result);
    } catch (error) {
      if (task.showRetry(error)) {
        await task.postError(error, complete: false);
        await restartTask(task);
      } else {
        await task.postError(error, complete: true);
      }
    }
  }

  @mustCallSuper
  Future<void> removeTask(Task task) async {
    workingTasks.remove(task);
  }

  @mustCallSuper
  Future<void> restartTask(Task task) async {
    try {
      await task.preRestart();
      final taskFuture = task.createTask();
      workingTasks.add(task);
      await task.postRestart();

      final result = await taskFuture;
      await task.postReceive(result);
    } catch (error) {
      if (task.showRetry(error)) {
        await task.postError(error, complete: false);
        await restartTask(task);
      } else {
        await task.postError(error, complete: true);
      }
    }
  }

  /// 返回当前运行中的 [Task]
  List<Task<dynamic>> getTasks() {
    return workingTasks;
  }

  /// 查找类型符合 [T] 的 [Task]
  List<T> getTasksByType<T extends Task<dynamic>>() {
    return workingTasks.whereType<T>().toList();
  }
}
