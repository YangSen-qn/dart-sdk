import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../../../qiniu_sdk_base.dart';
import '../../../task/task_manager.dart';
import '../../../resource/resource.dart';
import '../../../task/request_task.dart';
import '../../../task/request_task_controller.dart';

part 'cache_mixin.dart';
part 'complete_parts_task.dart';
part 'init_parts_task.dart';
part 'part.dart';
part 'upload_part_task.dart';
part 'upload_parts_task.dart';

/// 分片上传任务
class PutByPartTask extends RequestTask<PutResponse> {
  final String token;
  final Resource resource;

  final PutOptions options;

  /// 当前正在使用的区域索引
  int _regionIndex = 0;

  /// 上次错误
  Object? _error;

  /// 是否应该重试，本任务只处理区域间的重试
  bool shouldRetry = true;

  PutByPartTask({
    required Config config,
    required this.resource,
    required this.token,
    required this.options,
  }) : super(config, controller: options.controller);

  RequestTaskController? _currentWorkingTaskController;

  @override
  String taskID() {
    return resource.id;
  }

  @override
  Future<void> preStart() async {
    await super.preStart();

    // controller 被取消后取消当前运行的子任务
    controller?.cancelToken.whenCancel.then((_) {
      _currentWorkingTaskController?.cancel();
    });

    controller?.notifyStatusListeners(StorageStatus.Request);
  }

  @override
  Future<void> postReceive(PutResponse data) async {
    await resource.close();
    await super.postReceive(data);
    _currentWorkingTaskController = null;
  }

  @override
  Future<void> postError(Object error, {bool complete = false}) async {
    await resource.close();
    await super.postError(error, complete: complete);
  }

  @override
  Future<void> preRestart() async {
    controller?.notifyStatusListeners(StorageStatus.Retry);
    await super.preRestart();
  }

  @override
  bool showRetry(Object error) {
    return shouldRetry;
  }

  @override
  Future<PutResponse> createTask() async {
    final taskManager = TaskManager();

    InitParts? initParts;
    InitPartsTask? initPartsTask;
    UploadPartsTask? uploadPartsTask;

    try {
      await resource.open();

      initPartsTask = _createInitPartsTask(_regionIndex);
      taskManager.addTask(initPartsTask);
      _currentWorkingTaskController = initPartsTask.controller;
      initParts = await initPartsTask.future;

      /// 初始化任务完成后也告诉外部一个进度
      controller?.notifyProgressListeners(0.002);

      uploadPartsTask = _createUploadPartsTask(
        _regionIndex,
        initParts.uploadId,
      );
      _currentWorkingTaskController = uploadPartsTask.controller;
      taskManager.addTask(uploadPartsTask);

      final parts = await uploadPartsTask.future;
      final completePartsTask = _createCompletePartsTask(
        _regionIndex,
        initParts.uploadId,
        parts,
      );
      _currentWorkingTaskController = completePartsTask.controller;
      taskManager.addTask(completePartsTask);
      final putResponse = await completePartsTask.future;

      /// 上传完成，清除缓存
      await initPartsTask.clearCache();
      await uploadPartsTask.clearCache();
      return putResponse;
    } catch (error) {
      if (error is! StorageError) {
        // 不是 StorageError，直接抛出
        shouldRetry = false;
        rethrow;
      }

      /// 满足以下两种情况清理缓存：
      /// 1、如果服务端临时文件数据被删除了，清除本地缓存
      /// 2、源读取异常，之前上传的数据无效
      /// 不切换区域进行重试
      if (isCtxExpiedError(error.code) ||
          error.type == StorageErrorType.RESOURCE_READ_EXCEPTION) {
        await initPartsTask?.clearCache();
        await uploadPartsTask?.clearCache();
        return Future.error(error);
      }

      if (error.type == StorageErrorType.NO_AVAILABLE_REGION) {
        // 没有可用的区域了，停止重试
        shouldRetry = false;
        return Future.error(_error ?? error);
      }

      if (error.type == StorageErrorType.CANCEL ||
          !isRegionRetryableError(error)) {
        // 没有可用的服务器了，停止重试
        shouldRetry = false;
        return Future.error(error);
      }

      _regionIndex++;
      _error = error;
      rethrow;
    }
  }

  /// 初始化上传信息，分片上传的第一步
  InitPartsTask _createInitPartsTask(int regionIndex) {
    final controller = PutController();

    final task = InitPartsTask(
      config: config,
      resource: resource,
      token: token,
      key: options.key,
      controller: controller,
      accelerateUploading: options.accelerateUploading,
      regionIndex: regionIndex,
    );

    return task;
  }

  UploadPartsTask _createUploadPartsTask(int regionIndex, String uploadId) {
    final controller = PutController();

    final task = UploadPartsTask(
      config: config,
      token: token,
      partSize: options.partSize,
      uploadId: uploadId,
      maxPartsRequestNumber: options.maxPartsRequestNumber,
      resource: resource,
      controller: controller,
      accelerateUploading: options.accelerateUploading,
      regionIndex: regionIndex,
    );

    controller.addSendProgressListener(onSendProgress);
    return task;
  }

  /// 创建文件，分片上传的最后一步
  CompletePartsTask _createCompletePartsTask(
    int regionIndex,
    String uploadId,
    List<Part> parts,
  ) {
    final controller = PutController();
    final task = CompletePartsTask(
      config: config,
      token: token,
      uploadId: uploadId,
      parts: parts,
      key: options.key ?? resource.name,
      mimeType: options.mimeType,
      customVars: options.customVars,
      controller: controller,
      accelerateUploading: options.accelerateUploading,
      regionIndex: regionIndex,
    );

    return task;
  }
}
