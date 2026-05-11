part of 'put_parts_task.dart';

// 批处理上传 parts 的任务，为 [CompletePartsTask] 提供 [Part]
class UploadPartsTask extends RequestTask<List<Part>> with CacheMixin {
  final String token;
  final String uploadId;
  final bool accelerateUploading;
  final int regionIndex;

  final int partSize;
  final int maxPartsRequestNumber;

  @override
  late final String _cacheKey;

  /// 设置为 0，避免子任务重试失败后 [UploadPartsTask] 继续重试
  @override
  int get retryLimit => 0;

  // 文件总共被拆分的分片数
  late final int _totalPartCount;

  // 上传成功后把 part 信息存起来
  final Map<int, Part> _uploadedPartMap = {};

  // 处理分片上传任务的 UploadPartTask 的控制器
  final List<RequestTaskController> _workingUploadPartTaskControllers = [];

  // 已发送分片数量（实数形式）
  //
  // 整数部分表示"已完成 / 跳过的分片数"，小数部分累计了"当前在传分片"的进度，
  // 通过累加每片 onSendProgress 的 delta-percent 得到，
  // 支持分片内（次级切片粒度）的细粒度发送进度。
  // 配合 [_partProgressMap] 处理 retry / 跳过缓存分片的回滚和补偿。
  double _sentPartCount = 0;

  // 记录每个 partNumber 上一次报告的 percent，用于算 delta。
  // retry 时 dio 会从 0 重新累积 percent，监测到 percent < last 即视为回到 0 重发，
  // 需要先把上一轮的累计退还再按新值累加。
  final Map<int, double> _partProgressMap = {};

  // 已发送到服务器的数量
  int _sentPartToServerCount = 0;

  // 剩余多少被允许的请求数
  late int _idleRequestNumber;

  final Resource resource;

  UploadPartsTask({
    required this.token,
    required this.uploadId,
    required this.partSize,
    required this.maxPartsRequestNumber,
    required this.resource,
    PutController? controller,
    this.accelerateUploading = false,
    this.regionIndex = 0,
  }) : super(controller: controller);

  static String getCacheKey(
    String resourceId,
    int partSize,
    String? key,
  ) {
    final keyList = [
      'resource_id/$resourceId',
      'key/$key',
      'part_size/$partSize',
    ];

    return 'qiniu_dart_sdk_upload_parts_task@[${keyList..join("/")}]';
  }

  @override
  Future<void> preStart() async {
    await super.preStart();
    // 当前 controller 被取消后，所有运行中的子任务都需要被取消
    controller?.cancelToken.whenCancel.then((_) {
      for (final controller in _workingUploadPartTaskControllers) {
        controller.cancel();
      }
    });
    _idleRequestNumber = maxPartsRequestNumber;
    _totalPartCount = (resource.length / resource.chunkSize).ceil();
    _cacheKey = getCacheKey(resource.id, resource.length, resource.name);
  }

  @override
  void postError(Object error) {
    super.postError(error);
    // 取消，网络问题等可能导致上传中断，缓存已上传的分片信息
    storeUploadedPart();
  }

  Future storeUploadedPart() async {
    if (_uploadedPartMap.isEmpty) {
      return;
    }

    await setCache(jsonEncode(_uploadedPartMap.values.toList()));
  }

  // 从缓存恢复已经上传的 part
  Future recoverUploadedPart() async {
    // 获取缓存
    final cachedData = await getCache();
    // 尝试从缓存恢复
    if (cachedData != null) {
      var cachedList = <Part>[];

      try {
        final cachedList0 = json.decode(cachedData) as List<dynamic>;
        cachedList = cachedList0
            .map((dynamic item) => Part.fromJson(item as Map<String, dynamic>))
            .toList();
      } catch (error) {
        rethrow;
      }

      for (final part in cachedList) {
        _uploadedPartMap[part.partNumber] = part;
      }
    }
  }

  @override
  Future<List<Part>> createTask() async {
    /// 如果已经取消了，直接报错
    // ignore: null_aware_in_condition
    if (controller != null && controller!.isCancelled) {
      throw StorageError(type: StorageErrorType.CANCEL);
    }

    controller?.notifyStatusListeners(StorageStatus.Request);

    // 尝试恢复缓存，如果有
    await recoverUploadedPart();
    // 上传分片
    await _uploadParts();
    return _uploadedPartMap.values.toList();
  }

  int _uploadingPartIndex = 0;

  // 从指定的分片位置往后上传切片
  Future<void> _uploadParts() async {
    final taskFutures = <Future<void>>[];
    final tasksLength =
        min(_idleRequestNumber, _totalPartCount - _uploadingPartIndex);

    while (taskFutures.length < tasksLength &&
        _uploadingPartIndex < _totalPartCount) {
      // partNumber 按照后端要求必须从 1 开始
      final partNumber = ++_uploadingPartIndex;

      await for (final bytes in resource.stream) {
        // 跳过上传过的分片
        final uploadedPart = _uploadedPartMap[partNumber];
        if (uploadedPart != null) {
          // 缓存命中：直接按"整片完成"计入，并占位防止后续重复累计
          _sentPartCount += 1.0;
          _partProgressMap[partNumber] = 1.0;
          _sentPartToServerCount++;
          notifySendProgress();
          notifyProgress();
        } else {
          final future =
              _createUploadPartTaskFutureByPartNumber(bytes, partNumber);

          taskFutures.add(future);
        }
        break;
      }
    }

    await Future.wait<void>(taskFutures);
  }

  Future<void> _createUploadPartTaskFutureByPartNumber(
    List<int> bytes,
    int partNumber,
  ) async {
    _idleRequestNumber--;
    final controller = PutController();
    _workingUploadPartTaskControllers.add(controller);

    final task = UploadPartTask(
      token: token,
      bytes: bytes,
      uploadId: uploadId,
      byteLength: bytes.length,
      partNumber: partNumber,
      partSize: partSize,
      key: resource.name,
      controller: controller,
      accelerateUploading: accelerateUploading,
      regionIndex: regionIndex,
    );

    controller
      // 子任务请求体次级切片后，dio 会按 sub-chunk 频率触发本回调，
      // percent ∈ [0, 1] 表示当前分片自身的发送进度。
      // 这里把"本片 percent 相对上次的增量"累加到 [_sentPartCount]，
      // 让外层进度具备分片内细粒度。retry 检测：percent 比上次小说明回到 0 重发，
      // 先回滚上一轮的累计，再用新值累加（仅依赖 percent 单调性，不依赖 task.isRetrying）。
      ..addSendProgressListener((percent) {
        final last = _partProgressMap[partNumber] ?? 0.0;
        // delta 正常情况下为正（percent 单调递增）；retry 时 dio 会从 0 重新累计，
        // delta 为负，相当于自动回滚上一轮的累计，再用新 percent 重新累加。
        _sentPartCount += percent - last;
        _partProgressMap[partNumber] = percent;
        notifySendProgress();
      })
      // UploadPartTask 上传完成后触发
      ..addProgressListener((percent) {
        _sentPartToServerCount++;
        notifyProgress();
      });

    manager.addTask(task);

    final data = await task.future;

    _idleRequestNumber++;
    _uploadedPartMap[partNumber] =
        Part(partNumber: partNumber, etag: data.etag);
    _workingUploadPartTaskControllers.remove(controller);

    await storeUploadedPart();

    // 检查任务是否已经完成
    if (_uploadedPartMap.length != _totalPartCount) {
      // 上传下一片
      await _uploadParts();
    }
  }

  void notifySendProgress() {
    controller?.notifySendProgressListeners(_sentPartCount / _totalPartCount);
  }

  void notifyProgress() {
    controller?.notifyProgressListeners(
      _sentPartToServerCount /
          _totalPartCount *
          RequestTask.onSendProgressTakePercentOfTotal,
    );
  }
}
