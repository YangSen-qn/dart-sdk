part of 'request_task.dart';

@Deprecated('RequestTaskManager 已废弃，请直接使用 TaskManager')
class RequestTaskManager extends TaskManager {
  late final Config config;

  RequestTaskManager({
    required this.config,
  });

  @override
  Future<void> addTask(covariant RequestTask task) async {
    await super.addTask(task);
  }
}
