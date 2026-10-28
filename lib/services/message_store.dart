
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/blousab_message.dart';

class MessageStore {
  String _storageKey(String conversationId) =>
      'wasl_messages_$conversationId';

  Future<List<BlousabMessage>> getMessages(String conversationId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey(conversationId));

    if (raw == null || raw.isEmpty) {
      return [];
    }

    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      final messages = decoded
          .map(
            (item) => BlousabMessage.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList();

      messages.sort((a, b) => a.sentAt.compareTo(b.sentAt));
      return messages;
    } catch (_) {
      return [];
    }
  }

  Future<void> saveMessage(BlousabMessage message) async {
    final prefs = await SharedPreferences.getInstance();
    final messages = await getMessages(message.conversationId);

    // منع تكرار الرسالة نفسها عند حفظها مرة أخرى.
    if (messages.any((item) => item.id == message.id)) {
      return;
    }

    messages.add(message);

    await prefs.setString(
      _storageKey(message.conversationId),
      jsonEncode(messages.map((item) => item.toJson()).toList()),
    );
  }

  Future<void> clearMessages(String conversationId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey(conversationId));
  }
}