part of 'request_task.dart';

class _HostProvider extends HostProvider {
  final HostProvider _hostprovider;

  bool _hasGetUpHost = false;

  _HostProvider(this._hostprovider);

  @override
  Future<String> getUpHost({
    required String accessKey,
    required String bucket,
    bool accelerateUploading = false,
    bool transregional = false,
    int regionIndex = 0,
  }) async {
    while (true) {
      try {
        final host = await _hostprovider.getUpHost(
          accessKey: accessKey,
          bucket: bucket,
          accelerateUploading: accelerateUploading,
          transregional: transregional,
          regionIndex: regionIndex,
        );
        _hasGetUpHost = true;
        return host;
      } on StorageError catch (error) {
        if (_hasGetUpHost) {
          rethrow;
        }
        if (error.type != StorageErrorType.NO_AVAILABLE_HOST) {
          rethrow;
        }
        // 如果第一次获取上传域名就失败，尝试解冻一个上传域名后重试一次
        _hostprovider.unfreezeOne();
        continue;
      }
    }
  }

  @override
  void freezeHost(String host) {
    _hostprovider.freezeHost(host);
  }

  @override
  bool isFrozen(String host) {
    return _hostprovider.isFrozen(host);
  }

  @override
  void unfreezeOne() {
    _hostprovider.unfreezeOne();
  }
}

class RequestTaskManager extends TaskManager {
  final Config config;

  RequestTaskManager({
    required this.config,
  });

  @override
  void addTask(covariant RequestTask task) {
    task.config = Config(
      hostProvider: _HostProvider(config.hostProvider),
      cacheProvider: config.cacheProvider,
      httpClientAdapter: config.httpClientAdapter,
      retryLimit: config.retryLimit,
    );
    super.addTask(task);
  }
}
