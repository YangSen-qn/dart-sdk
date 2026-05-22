import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

/// Native 平台：当 [sendBufferSize] 非空时构造带 connectionFactory 的
/// [IOHttpClientAdapter]，通过 SO_SNDBUF 限制内核发送缓冲以配合写超时检测。
HttpClientAdapter createDefaultDelegate(int? sendBufferSize) {
  if (sendBufferSize == null) return HttpClientAdapter();

  return IOHttpClientAdapter(
    createHttpClient: () {
      final client = HttpClient();
      final option = _buildSndBufOption(sendBufferSize);
      if (option != null) {
        client.connectionFactory = (uri, proxyHost, proxyPort) async {
          final isDirectHttps = uri.isScheme('https') && proxyHost == null;
          final host = proxyHost ?? uri.host;
          final port = proxyPort ?? uri.port;
          final ConnectionTask<Socket> task = isDirectHttps
              ? await SecureSocket.startConnect(host, port)
              : await Socket.startConnect(host, port);
          task.socket.then((socket) {
            try {
              socket.setRawOption(option);
            } catch (e) {
              print('[DIAG] setRawOption failed: $e');
            }
          });
          return task;
        };
      }
      return client;
    },
  );
}

/// 按平台构造 SO_SNDBUF 的 [RawSocketOption]。
RawSocketOption? _buildSndBufOption(int size) {
  int? optionName;
  if (Platform.isLinux || Platform.isAndroid || Platform.isFuchsia) {
    optionName = 7;
  } else if (Platform.isMacOS || Platform.isIOS) {
    optionName = 0x1001;
  } else if (Platform.isWindows) {
    optionName = 0x1001;
  }
  if (optionName == null) return null;
  return RawSocketOption.fromInt(
    RawSocketOption.levelSocket,
    optionName,
    size,
  );
}
