import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/container_binding.dart';
import '../models/listener.dart';

class Services {
  static Future<List<ListenerObject>> discoverListeners({
    bool admin = false,
  }) async {
    final command = Platform.isWindows
        ? <String>['netstat', '-ano']
        : <String>['ss', '-H', '-ltnup'];
    if (admin && !Platform.isWindows) command.insertAll(0, ['pkexec']);
    late ProcessResult result;
    try {
      result = await runCommand(command);
    } on TimeoutException {
      throw Exception('Listener discovery timed out.');
    } on ProcessException catch (error) {
      throw Exception(error.message);
    }
    if (result.exitCode != 0) {
      throw Exception(
        '${result.stderr}'.trim().isEmpty
            ? 'Listener discovery failed.'
            : result.stderr,
      );
    }
    final listeners = Platform.isWindows
        ? parseNetstatListeners('${result.stdout}')
        : parseListeners('${result.stdout}');
    final bindings = await discoverDockerBindings();
    return listeners.map((listener) => correlate(listener, bindings)).toList()
      ..sort(
        (a, b) => a.port != b.port
            ? a.port.compareTo(b.port)
            : a.protocol.compareTo(b.protocol),
      );
  }

  static List<ListenerObject> parseNetstatListeners(String output) {
    final listeners = <ListenerObject>[];
    for (final line in output.split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 4) continue;
      final protocol = parts.first.toLowerCase();
      if (protocol != 'tcp' && protocol != 'udp') continue;
      final endpoint = parseEndpoint(parts[1]);
      if (endpoint == null) continue;
      if (protocol == 'tcp' &&
          (parts.length < 5 || parts[3].toUpperCase() != 'LISTENING')) {
        continue;
      }
      final pid = int.tryParse(parts.last);
      if (pid == null) continue;
      listeners.add(
        ListenerObject(
          protocol: protocol,
          address: endpoint.$1,
          port: endpoint.$2,
          pid: pid,
        ),
      );
    }
    return listeners;
  }

  static Future<List<ContainerBinding>> discoverDockerBindings() async {
    try {
      final result = await runCommand([
        'docker',
        'ps',
        '--format',
        '{{json .}}',
      ], timeout: const Duration(seconds: 5));
      if (result.exitCode != 0) return [];
      final bindings = <ContainerBinding>[];
      for (final line in '${result.stdout}'.split('\n')) {
        try {
          final item = jsonDecode(line) as Map<String, dynamic>;
          final id = item['ID'];
          final ports = item['Ports'];
          if (id is! String || id.isEmpty || ports is! String) continue;
          final rawName = item['Names'];
          final name = rawName is String && rawName.isNotEmpty
              ? rawName
              : id.substring(0, id.length.clamp(0, 12));
          final pattern = RegExp(
            r'(?:^|,\s*)(\[[^]]+\]|[^:,\s]+):(\d+)->\d+\/(tcp|udp)',
            caseSensitive: false,
          );
          for (final match in pattern.allMatches(ports)) {
            final address = normalizeAddress(match.group(1)!);
            if (address != null) {
              bindings.add(
                ContainerBinding(
                  address,
                  int.parse(match.group(2)!),
                  match.group(3)!.toLowerCase(),
                  id,
                  name,
                ),
              );
            }
          }
        } catch (_) {}
      }
      return bindings;
    } catch (_) {
      return [];
    }
  }

  static Future<ProcessResult> runCommand(
    List<String> command, {
    Duration timeout = const Duration(seconds: 15),
  }) {
    return Process.run(command.first, command.sublist(1)).timeout(timeout);
  }

  static List<ListenerObject> parseListeners(String output) {
    final listeners = <ListenerObject>[];
    final processPattern = RegExp(r'users:\(\("([^"]+)",pid=(\d+)');
    for (final line in output.split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 5 ||
          !{'tcp', 'udp'}.contains(parts.first.toLowerCase())) {
        continue;
      }
      final endpoint = parseEndpoint(parts[4]);
      if (endpoint == null) continue;
      final match = processPattern.firstMatch(parts.skip(5).join(' '));
      listeners.add(
        ListenerObject(
          protocol: parts.first.toLowerCase(),
          address: endpoint.$1,
          port: endpoint.$2,
          process: match?.group(1) ?? '-',
          pid: match == null ? null : int.tryParse(match.group(2)!),
        ),
      );
    }
    return listeners;
  }

  static (String, int)? parseEndpoint(String value) {
    if (value.startsWith('[')) {
      final match = RegExp(r'^\[([^]]+)\]:(\d+)$').firstMatch(value);
      return match == null
          ? null
          : (match.group(1)!, int.parse(match.group(2)!));
    }
    final separator = value.lastIndexOf(':');
    if (separator < 1) return null;
    final port = int.tryParse(value.substring(separator + 1));
    return port == null || port < 0 || port > 65535
        ? null
        : (value.substring(0, separator), port);
  }

  static ListenerObject correlate(
    ListenerObject listener,
    List<ContainerBinding> bindings,
  ) {
    final address = normalizeAddress(listener.address);
    if (address == null) return listener;
    final matches = bindings.where(
      (binding) =>
          binding.hostPort == listener.port &&
          binding.protocol == listener.protocol,
    );
    final exact = matches
        .where((binding) => binding.address == address)
        .toList();
    if (exact.length != 1) return listener;
    final binding = exact.first;
    return ListenerObject(
      protocol: listener.protocol,
      address: listener.address,
      port: listener.port,
      process: binding.name,
      pid: listener.pid,
      containerId: binding.id,
      containerName: binding.name,
    );
  }
}
