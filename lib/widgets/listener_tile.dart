import 'package:flutter/material.dart';

import '../models/listener.dart';

class ListenerTile extends StatelessWidget {
  const ListenerTile({super.key, required this.listener, required this.onStop});
  final ListenerObject listener;
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
