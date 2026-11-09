// The part of the Model Context Protocol Mochi's tool server speaks (Swift `MCPServerCore`): the handshake, the tool
// list and tool calls, as newline-delimited JSON-RPC 2.0. Transport and tool execution live elsewhere (paws_server.dart,
// ask_brain.dart); this is pure, so it can be tested.

import 'dart:convert';

/// A tool Mochi's helper Claude session can call.
class McpTool {
  const McpTool({
    required this.name,
    required this.description,
    this.properties = const {},
    this.required = const [],
    this.enumValues = const {},
  });

  final String name;
  final String description;

  /// `name: (type, description)`.
  final Map<String, (String, String)> properties;
  final List<String> required;
  final Map<String, List<String>> enumValues;

  Map<String, Object?> get inputSchema => {
    'type': 'object',
    'properties': {
      for (final MapEntry(:key, :value) in properties.entries)
        key: {'type': value.$1, 'description': value.$2, if (enumValues[key] != null) 'enum': enumValues[key]},
    },
    'required': required,
    'additionalProperties': false,
  };
}

sealed class McpOutcome {
  const McpOutcome();
}

/// Send this line back now.
class McpReply extends McpOutcome {
  const McpReply(this.line);

  final String line;
}

/// Run the tool, then send [McpServerCore.toolResult].
class McpCall extends McpOutcome {
  const McpCall({required this.id, required this.name, required this.arguments});

  final Object id;
  final String name;
  final Map<String, Object?> arguments;
}

/// Notifications and responses need no answer.
class McpIgnore extends McpOutcome {
  const McpIgnore();
}

class McpServerCore {
  const McpServerCore({required this.name, required this.version, this.instructions, required this.tools});

  static const List<String> supportedVersions = ['2024-11-05', '2025-03-26', '2025-06-18', '2025-11-25'];
  static const String fallbackVersion = '2025-06-18';

  final String name;
  final String version;
  final String? instructions;
  final List<McpTool> tools;

  /// The tools' names, in order.
  List<String> get toolNames => [for (final tool in tools) tool.name];

  McpOutcome handle(String line) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      return McpReply(error(null, -32700, 'Parse error'));
    }
    if (decoded is! Map) return McpReply(error(null, -32700, 'Parse error'));
    final method = decoded['method'];
    final Object? id = decoded['id'];
    if (method is! String || id == null) return const McpIgnore();
    final params = decoded['params'] is Map ? Map<String, Object?>.from(decoded['params'] as Map) : <String, Object?>{};
    switch (method) {
      case 'initialize':
        final requested = params['protocolVersion'];
        return McpReply(
          response(id, {
            'protocolVersion': supportedVersions.contains(requested) ? requested : fallbackVersion,
            'capabilities': {'tools': <String, Object?>{}},
            'serverInfo': {'name': name, 'version': version},
            'instructions': ?instructions,
          }),
        );
      case 'ping':
        return McpReply(response(id, <String, Object?>{}));
      case 'tools/list':
        return McpReply(
          response(id, {
            'tools': [
              for (final tool in tools) {'name': tool.name, 'description': tool.description, 'inputSchema': tool.inputSchema},
            ],
          }),
        );
      case 'tools/call':
        final tool = params['name'];
        if (tool is! String || !tools.any((candidate) => candidate.name == tool)) {
          return McpReply(toolResult(id, 'Unknown tool.', isError: true));
        }
        final arguments = params['arguments'];
        return McpCall(id: id, name: tool, arguments: arguments is Map ? Map<String, Object?>.from(arguments) : <String, Object?>{});
      default:
        return McpReply(error(id, -32601, 'Method not found'));
    }
  }

  /// A tool's answer: one text block.
  static String toolResult(Object id, String text, {bool isError = false}) => response(id, {
    'content': [
      {'type': 'text', 'text': text},
    ],
    'isError': isError,
  });

  static String response(Object id, Map<String, Object?> result) => '${jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result})}\n';

  static String error(Object? id, int code, String message) =>
      '${jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message},
      })}\n';
}
