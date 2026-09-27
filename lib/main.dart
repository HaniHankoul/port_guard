import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'models/action_result.dart';
import 'models/listener.dart';
import 'repo/services.dart';
import 'widgets/empty_state.dart';
import 'widgets/listener_tile.dart';

void main() => runApp(const MainApp());

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Port Guard',
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

class PortGuardianPage extends StatefulWidget {
  const PortGuardianPage({super.key});

  @override
  State<PortGuardianPage> createState() => _PortGuardianPageState();
}

class _PortGuardianPageState extends State<PortGuardianPage> {
  final searchController = TextEditingController();
  List<ListenerObject> entries = [];
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
      final result = await Services.discoverListeners(admin: adminScan);
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

  List<ListenerObject> get visibleEntries {
    final query = searchController.text.trim().toLowerCase();
    return entries
        .where((entry) => query.isEmpty || entry.searchable.contains(query))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = error != null
        ? EmptyState(
            icon: Icons.warning_amber_rounded,
            title: 'Unable to scan sockets',
            detail: error!,
          )
        : visibleEntries.isEmpty
        ? EmptyState(
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

  Future<void> confirmStop(ListenerObject listener) async {
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
              'Stop $target?\n\nListening socket: ${listener.address}:${listener.port}/${listener.protocol}\n\n${Platform.isWindows ? 'Windows requires forced process termination for this action.' : 'The owner receives SIGTERM. Port Guardian never silently sends SIGKILL.'}',
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

  Future<void> stop(ListenerObject listener) async {
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
    if (Platform.isWindows) {
      final result = await Services.runCommand([
        'taskkill',
        '/PID',
        '$pid',
        '/T',
        '/F',
      ], timeout: const Duration(seconds: 5));
      return result.exitCode == 0
          ? const ActionResult(true, 'The process termination was requested.')
          : ActionResult(
              false,
              '${result.stderr}'.trim().isEmpty
                  ? 'Permission or termination was denied.'
                  : '${result.stderr}'.trim(),
            );
    }
    var result = await Services.runCommand([
      'kill',
      '-TERM',
      '$pid',
    ], timeout: const Duration(seconds: 3));
    if (result.exitCode != 0 &&
        '${result.stderr}'.toLowerCase().contains('permission')) {
      result = await Services.runCommand(['pkexec', 'kill', '-TERM', '$pid']);
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
    final result = await Services.runCommand([
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
    final result = await Services.runCommand([
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
