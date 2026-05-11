part of 'put_parts_task.dart';

/// 分片上传请求体的"次级切片"大小（字节）。
///
/// 单个分片通常 4MB 起步，如果作为一整段 `Stream.value(bytes)` 喂给 dio，
/// 底层 IOSink 只会触发一次 pause/resume，导致 [QiniuHttpClient] 的写阶段
/// 闲时超时（pause-driven）粒度过粗——一片真实传输 20s 才会 resume 一次。
///
/// 这里再切成 256KB 的小段串流，IOSink 会逐段 pause/resume，
/// 闲时超时探测的时间粒度恢复到「写不动 256KB 就报警」的层级。
/// 与 [QiniuHttpClient.sendBufferSize] 默认值（256KB）匹配：每片刚好填满一次内核
/// send buffer，IOSink 每片 1 次 pause/resume，避免双重限流导致 TCP 拥塞窗口塌陷，
/// 同时也避免 microtask round-trip 过多影响吞吐。
const int _kUploadPartChunkBytes = 256 * 1024;

/// 把整段 bytes 按 [chunkSize] 切成多个 chunk，通过 `async*` 串成 Stream。
///
/// 关键：`async*` 函数受订阅 pause/resume 控制，下游一旦 pause 就不会再 yield，
/// 这正是 pause-driven 写超时所需的语义。
Stream<List<int>> _chunkedStream(List<int> bytes, int chunkSize) async* {
  for (var offset = 0; offset < bytes.length; offset += chunkSize) {
    final end = (offset + chunkSize < bytes.length) ? offset + chunkSize : bytes.length;
    // Uint8List 走 sublistView 零拷贝（共享底层 buffer），普通 List<int> 才 sublist。
    yield bytes is Uint8List ? Uint8List.sublistView(bytes, offset, end) : bytes.sublist(offset, end);
  }
}

// 上传一个 part 的任务
class UploadPartTask extends RequestTask<UploadPart> {
  final String token;
  final String uploadId;
  final List<int> bytes;
  final int partSize;
  final bool accelerateUploading;
  final int regionIndex;

  // 如果 data 是 Stream 的话，Dio 需要判断 content-length 才会调用 onSendProgress
  // https://github.com/cfug/dio/blob/v5.0.0/dio/lib/src/dio_mixin.dart#L633
  final int byteLength;

  final int partNumber;

  final String? key;

  late final UpTokenInfo _tokenInfo;

  UploadPartTask({
    required this.token,
    required this.bytes,
    required this.uploadId,
    required this.byteLength,
    required this.partNumber,
    required this.partSize,
    this.key,
    PutController? controller,
    this.accelerateUploading = false,
    this.regionIndex = 0,
  }) : super(controller: controller);

  @override
  Future<void> preStart() async {
    _tokenInfo = Auth.parseUpToken(token);
    await super.preStart();
  }

  @override
  void postReceive(data) {
    controller?.notifyProgressListeners(1);
    super.postReceive(data);
  }

  @override
  Future<UploadPart> createTask() async {
    final headers = <String, dynamic>{
      'Authorization': 'UpToken $token',
      Headers.contentLengthHeader: byteLength,
    };

    final bucket = _tokenInfo.putPolicy.getBucket();

    final host = await config.hostProvider.getUpHost(
      bucket: bucket,
      accessKey: _tokenInfo.accessKey,
      accelerateUploading: accelerateUploading,
      regionIndex: regionIndex,
    );

    final encodedKey = key != null ? base64Url.encode(utf8.encode(key!)) : '~';
    final paramUrl = '$host/buckets/$bucket/objects/$encodedKey/uploads/$uploadId/$partNumber';

    final response = await client.put<Map<String, dynamic>>(
      paramUrl,
      data: _chunkedStream(bytes, _kUploadPartChunkBytes),
      // 在 data 是 stream 的场景下， interceptor 传入 cancelToken 这里不传会有 bug
      cancelToken: controller?.cancelToken,
      options: Options(
        headers: headers,
        contentType: 'application/octet-stream',
      ),
    );
    checkResponse(response);

    return UploadPart.fromJson(response.data!);
  }

  // 分片上传是手动从 File 拿一段数据大概 4m(直穿是直接从 File 里面读取)
  // 如果文件是 21m，假设切片是 4 * 5
  // 外部进度的话会导致一下长到 90% 多，然后变成 100%
  // 解决方法是覆盖父类的 onSendProgress，让 onSendProgress 不处理 Progress 的进度
  // 改为发送成功后通知(见 postReceive)
  @override
  void onSendProgress(double percent) {
    controller?.notifySendProgressListeners(percent);
  }
}

// uploadPart 的返回体
class UploadPart {
  final String md5;
  final String etag;

  UploadPart({
    required this.md5,
    required this.etag,
  });

  factory UploadPart.fromJson(Map json) {
    return UploadPart(
      md5: json['md5'] as String,
      etag: json['etag'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'etag': etag,
      'md5': md5,
    };
  }
}
