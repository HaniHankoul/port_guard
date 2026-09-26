import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

void main() => runApp(const MainApp());

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Port Guardian',
    theme: ThemeData(
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff56c596),
        brightness: Brightness.dark,
        surface: const Color(0xff121a1b),
      ),
      scaffoldBackgroundColor: const Color(0xff0c1112),
      useMaterial3: true,
    ),
    home: const PortGuardianPage(),
  );
}

class Listener {
  const Listener({
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

class ContainerBinding {
  const ContainerBinding(
    this.address,
    this.hostPort,
    this.protocol,
    this.id,
    this.name,
  );
  final String address;
  final int hostPort;
  final String protocol;
  final String id;
  final String name;
}

class ActionResult {
  const ActionResult(this.success, this.message);
  final bool success;
  final String message;
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

Future<ProcessResult> runCommand(
  List<String> command, {
  Duration timeout = const Duration(seconds: 15),
}) {
  return Process.run(command.first, command.sublist(1)).timeout(timeout);
}

Future<List<Listener>> discoverListeners({bool admin = false}) async {
  final command = <String>['ss', '-H', '-ltnup'];
  if (admin) command.insertAll(0, ['pkexec']);
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
  final listeners = parseListeners('${result.stdout}');
  final bindings = await discoverDockerBindings();
  return listeners.map((listener) => correlate(listener, bindings)).toList()
    ..sort(
      (a, b) => a.port != b.port
          ? a.port.compareTo(b.port)
          : a.protocol.compareTo(b.protocol),
    );
}

List<Listener> parseListeners(String output) {
  final listeners = <Listener>[];
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
      Listener(
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

(String, int)? parseEndpoint(String value) {
  if (value.startsWith('[')) {
    final match = RegExp(r'^\[([^]]+)\]:(\d+)$').firstMatch(value);
    return match == null ? null : (match.group(1)!, int.parse(match.group(2)!));
  }
  final separator = value.lastIndexOf(':');
  if (separator < 1) return null;
  final port = int.tryParse(value.substring(separator + 1));
  return port == null || port < 0 || port > 65535
      ? null
      : (value.substring(0, separator), port);
}

Future<List<ContainerBinding>> discoverDockerBindings() async {
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

Listener correlate(Listener listener, List<ContainerBinding> bindings) {
  final address = normalizeAddress(listener.address);
  if (address == null) return listener;
  final matches = bindings.where(
    (binding) =>
        binding.hostPort == listener.port &&
        binding.protocol == listener.protocol,
  );
  final exact = matches.where((binding) => binding.address == address).toList();
  if (exact.length != 1) return listener;
  final binding = exact.first;
  return Listener(
    protocol: listener.protocol,
    address: listener.address,
    port: listener.port,
    process: binding.name,
    pid: listener.pid,
    containerId: binding.id,
    containerName: binding.name,
  );
}

class PortGuardianPage extends StatefulWidget {
  const PortGuardianPage({super.key});

  @override
  State<PortGuardianPage> createState() => _PortGuardianPageState();
}

class _PortGuardianPageState extends State<PortGuardianPage> {
  final searchController = TextEditingController();
  List<Listener> entries = [];
  bool adminScan = false;
  bool loading = false;
  String status = 'Ready to scan listening sockets';
  String? error;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  Future<void> refresh({bool? admin}) async {
    setState(() {
      loading = true;
      error = null;
      if (admin != null) adminScan = admin;
      status = 'Scanning listening sockets...';
    });
    try {
      final result = await discoverListeners(admin: adminScan);
      if (!mounted) return;
      setState(() {
        entries = result;
        loading = false;
        status =
            '${result.length} listening sockets • ${adminScan ? 'admin' : 'normal'} scan • Docker optional';
      });
    } catch (exception) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = exception.toString().replaceFirst('Exception: ', '');
        status = 'Could not read listening sockets';
      });
    }
  }

  List<Listener> get visibleEntries {
    final query = searchController.text.trim().toLowerCase();
    return entries
        .where((entry) => query.isEmpty || entry.searchable.contains(query))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = error != null
        ? _EmptyState(
            icon: Icons.warning_amber_rounded,
            title: 'Unable to scan sockets',
            detail: error!,
          )
        : visibleEntries.isEmpty
        ? _EmptyState(
            icon: Icons.lan_outlined,
            title: entries.isEmpty
                ? 'No listening sockets found'
                : 'No matching sockets',
            detail: entries.isEmpty
                ? 'Start a service and refresh to see it here.'
                : 'Try a different search term.',
          )
        : ListView.separated(
            itemCount: visibleEntries.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (_, index) => ListenerTile(
              listener: visibleEntries[index],
              onStop: () => confirmStop(visibleEntries[index]),
            ),
          );
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1180),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.shield_outlined,
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(width: 14),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Port Guardian',
                              style: TextStyle(
                                fontSize: 25,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              'Listening socket viewer',
                              style: TextStyle(color: Color(0xff94a4a2)),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Refresh listening ports',
                        onPressed: loading ? null : refresh,
                        icon: const Icon(Icons.refresh),
                      ),
                      const SizedBox(width: 4),
                      FilledButton.tonalIcon(
                        onPressed: loading ? null : () => refresh(admin: true),
                        icon: const Icon(
                          Icons.admin_panel_settings_outlined,
                          size: 18,
                        ),
                        label: const Text('Admin scan'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),
                  TextField(
                    controller: searchController,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: 'Filter by port, process, address, exposure, or source',
                      suffixIcon: searchController.text.isEmpty
                          ? null
                          : IconButton(
                              onPressed: () {
                                searchController.clear();
                                setState(() {});
                              },
                              icon: const Icon(Icons.clear),
                            ),
                      filled: true,
                      fillColor: const Color(0xff151e1f),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      if (loading)
                        const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      if (loading) const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          status,
                          style: TextStyle(
                            color: error == null
                                ? const Color(0xff94a4a2)
                                : theme.colorScheme.error,
                          ),
                        ),
                      ),
                      Text(
                        '${visibleEntries.length} shown',
                        style: const TextStyle(color: Color(0xff94a4a2)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Expanded(child: content),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> confirmStop(Listener listener) async {
    final target = listener.containerId != null
        ? 'Docker container ${listener.containerName}'
        : listener.pid != null
        ? 'process ${listener.process} (PID ${listener.pid})'
        : 'the process owning this socket (PID hidden)';
    final shouldStop =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Stop listener owner?'),
            content: Text(
              'Stop $target?\n\nListening socket: ${listener.address}:${listener.port}/${listener.protocol}\n\nThe owner receives SIGTERM. Port Guardian never silently sends SIGKILL.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                ),
                child: const Text('Stop'),
              ),
            ],
          ),
        ) ??
        false;
    if (shouldStop) await stop(listener);
  }

  Future<void> stop(Listener listener) async {
    setState(() => status = 'Requesting stop for port ${listener.port}...');
    final ActionResult result;
    if (listener.containerId != null) {
      result = await stopContainer(listener.containerId!);
    } else if (listener.pid != null) {
      result = await terminateProcess(listener.pid!);
    } else {
      result = await terminateByPort(listener.port, listener.protocol);
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(result.success ? 'Stopped' : 'Stop failed'),
        content: Text(result.message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (result.success) refresh();
  }
}

Future<ActionResult> terminateProcess(int pid) async {
  try {
    var result = await runCommand([
      'kill',
      '-TERM',
      '$pid',
    ], timeout: const Duration(seconds: 3));
    if (result.exitCode != 0 &&
        '${result.stderr}'.toLowerCase().contains('permission')) {
      result = await runCommand(['pkexec', 'kill', '-TERM', '$pid']);
    }
    return result.exitCode == 0
        ? const ActionResult(true, 'SIGTERM was sent to the process.')
        : ActionResult(
            false,
            '${result.stderr}'.trim().isEmpty
                ? 'Permission or termination was denied.'
                : '${result.stderr}'.trim(),
          );
  } catch (exception) {
    return ActionResult(false, 'Could not request permission: $exception');
  }
}

Future<ActionResult> terminateByPort(int port, String protocol) async {
  try {
    final result = await runCommand([
      'pkexec',
      'fuser',
      '-k',
      '-TERM',
      '-n',
      protocol,
      '$port',
    ]);
    return result.exitCode == 0 || result.exitCode == 1
        ? const ActionResult(true, 'SIGTERM was sent to the socket owner.')
        : ActionResult(
            false,
            '${result.stderr}'.trim().isEmpty
                ? 'Permission or termination was denied.'
                : '${result.stderr}'.trim(),
          );
  } catch (exception) {
    return ActionResult(false, 'Could not request permission: $exception');
  }
}

Future<ActionResult> stopContainer(String id) async {
  try {
    final result = await runCommand([
      'docker',
      'stop',
      id,
    ], timeout: const Duration(seconds: 30));
    return result.exitCode == 0
        ? const ActionResult(true, 'The container stopped.')
        : ActionResult(
            false,
            '${result.stderr}'.trim().isEmpty
                ? 'Docker could not stop the container.'
                : '${result.stderr}'.trim(),
          );
  } catch (_) {
    return const ActionResult(
      false,
      'Docker is not installed or is no longer available.',
    );
  }
}

class ListenerTile extends StatelessWidget {
  const ListenerTile({super.key, required this.listener, required this.onStop});
  final Listener listener;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final exposureColor = listener.exposure == 'Network exposed'
        ? const Color(0xffffb86b)
        : listener.exposure == 'Local only'
        ? const Color(0xff70d5a5)
        : const Color(0xff8ab4d6);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xff151e1f),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xff263332)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 62,
            child: Text(
              '${listener.port}',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${listener.protocol.toUpperCase()}  ${listener.address}:${listener.port}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    Text(
                      listener.process,
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      listener.pid == null
                          ? 'owner hidden'
                          : 'PID ${listener.pid}',
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      listener.source,
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      listener.exposure,
                      style: TextStyle(
                        color: exposureColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          IconButton(
            tooltip: 'Stop owner gracefully',
            onPressed: onStop,
            icon: Icon(
              Icons.stop_circle_outlined,
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.detail,
  });
  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 46, color: const Color(0xff5d716e)),
        const SizedBox(height: 14),
        Text(
          title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Text(detail, style: const TextStyle(color: Color(0xff94a4a2))),
      ],
    ),
  );
}
