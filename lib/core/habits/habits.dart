import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// On-device "habits" — a small, private record of how THIS person uses the app,
/// used to remove friction (remember servers, suggest the service they open
/// most). It never leaves the device — fitting the self-hosted, Tailscale-only
/// ethos — and it only ever *suggests* or prefills; side-effectful or sensitive
/// actions are never taken silently. Inspect it in Settings → Local data, and
/// it can be cleared like any other cached data.

/// A Vault server this device has connected to.
class ServerMemory {
  const ServerMemory({
    required this.host,
    required this.count,
    required this.lastUsed,
  });

  final String host;
  final int count;
  final DateTime lastUsed;

  ServerMemory bump() => ServerMemory(
        host: host,
        count: count + 1,
        lastUsed: DateTime.now(),
      );

  Map<String, Object?> toJson() => {
        'host': host,
        'count': count,
        'last': lastUsed.millisecondsSinceEpoch,
      };

  factory ServerMemory.fromJson(Map<String, Object?> j) => ServerMemory(
        host: j['host'] as String,
        count: (j['count'] as num?)?.toInt() ?? 1,
        lastUsed: DateTime.fromMillisecondsSinceEpoch(
            (j['last'] as num?)?.toInt() ?? 0),
      );
}

/// The learned state. Immutable; the notifier swaps a new one on each event.
class Habits {
  const Habits({
    this.servers = const [],
    this.serviceOpens = const {},
    this.lastServiceId,
    this.autoLand = true,
  });

  /// Every server ever connected to, most-recent first.
  final List<ServerMemory> servers;

  /// serviceId → number of intentional opens (the "most-used" signal).
  final Map<String, int> serviceOpens;

  /// The service open last — the "resume where I left off" signal.
  final String? lastServiceId;

  /// Open the most-used service on cold start (user-overridable in Settings).
  final bool autoLand;

  Habits copyWith({
    List<ServerMemory>? servers,
    Map<String, int>? serviceOpens,
    String? lastServiceId,
    bool? autoLand,
  }) =>
      Habits(
        servers: servers ?? this.servers,
        serviceOpens: serviceOpens ?? this.serviceOpens,
        lastServiceId: lastServiceId ?? this.lastServiceId,
        autoLand: autoLand ?? this.autoLand,
      );

  Map<String, Object?> toJson() => {
        'servers': [for (final s in servers) s.toJson()],
        'serviceOpens': serviceOpens,
        'lastServiceId': lastServiceId,
        'autoLand': autoLand,
      };

  factory Habits.fromJson(Map<String, Object?> j) => Habits(
        servers: [
          for (final s in (j['servers'] as List?) ?? const [])
            ServerMemory.fromJson(s as Map<String, Object?>),
        ],
        serviceOpens: {
          for (final e in ((j['serviceOpens'] as Map?) ?? const {}).entries)
            e.key as String: (e.value as num).toInt(),
        },
        lastServiceId: j['lastServiceId'] as String?,
        autoLand: (j['autoLand'] as bool?) ?? true,
      );
}

class HabitsNotifier extends AsyncNotifier<Habits> {
  static const _key = 'habits_v1';

  @override
  Future<Habits> build() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return const Habits();
    try {
      return Habits.fromJson(jsonDecode(raw) as Map<String, Object?>);
    } catch (_) {
      return const Habits();
    }
  }

  Future<void> _save(Habits h) async {
    state = AsyncData(h);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(h.toJson()));
  }

  /// Record a successful connect to [host] (upsert + recency bump).
  Future<void> recordServer(String host) async {
    final h = state.asData?.value ?? const Habits();
    final existing = h.servers.where((s) => s.host == host).firstOrNull;
    final updated = (existing ?? ServerMemory(host: host, count: 0, lastUsed: DateTime.now()))
        .bump();
    final servers = [
      updated,
      for (final s in h.servers) if (s.host != host) s,
    ]..sort((a, b) => b.lastUsed.compareTo(a.lastUsed));
    await _save(h.copyWith(servers: servers));
  }

  /// Forget a server (e.g. a typo the user wants gone).
  Future<void> forgetServer(String host) async {
    final h = state.asData?.value ?? const Habits();
    await _save(h.copyWith(
        servers: [for (final s in h.servers) if (s.host != host) s]));
  }

  /// Record an intentional open of [serviceId] (a dock/sidebar tap).
  Future<void> recordServiceOpen(String serviceId) async {
    final h = state.asData?.value ?? const Habits();
    await _save(h.copyWith(
      serviceOpens: {
        ...h.serviceOpens,
        serviceId: (h.serviceOpens[serviceId] ?? 0) + 1,
      },
      lastServiceId: serviceId,
    ));
  }

  /// Toggle auto-landing on the most-used service at startup.
  Future<void> setAutoLand(bool value) async {
    final h = state.asData?.value ?? const Habits();
    await _save(h.copyWith(autoLand: value));
  }
}

final habitsProvider =
    AsyncNotifierProvider<HabitsNotifier, Habits>(HabitsNotifier.new);

/// Known servers, most-recent first (empty while loading).
final knownServersProvider = Provider<List<ServerMemory>>(
  (ref) => ref.watch(habitsProvider).asData?.value.servers ?? const [],
);

/// The service opened most often, if any — the "auto-land" candidate.
final topServiceIdProvider = Provider<String?>((ref) {
  final opens = ref.watch(habitsProvider).asData?.value.serviceOpens ?? const {};
  if (opens.isEmpty) return null;
  return opens.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
});
