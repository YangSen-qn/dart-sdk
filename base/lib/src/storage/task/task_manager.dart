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
      task.manager = this;
      await task.preStart();

      workingTasks.add(task);

      final taskFuture = task.createTask();
      await task.postStart();
      await task.postReceive(await taskFuture);
    } catch (error) {
      await task.postError(error);
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
      await task.postRestart();
      await task.postReceive(taskFuture);
    } catch (error) {
      await task.postError(error);
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
