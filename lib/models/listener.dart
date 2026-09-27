import 'dart:io';

class ListenerObject {
  const ListenerObject({
    required this.protocol,
    required this.address,
    required this.port,
    this.process = '-',
    this.pid,
    this.containerId,
    this.containerName,
  });

  final String protocol;
  final String address;
  final int port;
  final String process;
  final int? pid;
  final String? containerId;
  final String? containerName;

  String get exposure {
    final normalized = normalizeAddress(address);
    if (normalized == null) return 'Unknown';
    if (normalized == '127.0.0.1' || normalized == '::1') return 'Local only';
    if (normalized == '0.0.0.0' || normalized == '::') return 'Network exposed';
    return 'Interface-specific';
  }

  String get source =>
      containerName == null ? 'Process' : 'Docker: $containerName';

  String get searchable =>
      '$protocol $address $port $process ${pid ?? ''} $source $exposure'
          .toLowerCase();
}

String? normalizeAddress(String value) {
  var address = value.trim();
  if (address.startsWith('[') && address.endsWith(']')) {
    address = address.substring(1, address.length - 1);
  }
  if (address == '*') return null;
  address = address.split('%').first;
  if (InternetAddress.tryParse(address) == null) return null;
  return InternetAddress(address).address;
}
