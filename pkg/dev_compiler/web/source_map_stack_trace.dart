// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:path/path.dart' as p;
import 'package:source_maps/source_maps.dart';
import 'package:stack_trace/stack_trace.dart';

/// This is a fork of package:source_map_stack_trace, a tool for
/// dart2js-compiled code, reworked for DDC.

/// Convert [stackTrace], a stack trace generated by DDC-compiled
/// JavaScript, to a native-looking stack trace using [sourceMap].
///
/// [roots] are the paths (usually `http:` URI strings) that DDC applications
/// are served from.  This is used to identify sdk and package URIs.
StackTrace mapStackTrace(Mapping sourceMap, StackTrace stackTrace,
    {List<String> roots}) {
  if (stackTrace is Chain) {
    return Chain(stackTrace.traces.map((trace) {
      return Trace.from(mapStackTrace(sourceMap, trace, roots: roots));
    }));
  }

  var trace = Trace.from(stackTrace);
  return Trace(trace.frames.map((frame) {
    // If there's no line information, there's no way to translate this frame.
    // We could return it as-is, but these lines are usually not useful anyways.
    if (frame.line == null) return null;

    // If there's no column, try using the first column of the line.
    var column = frame.column == null ? 0 : frame.column;

    // Subtract 1 because stack traces use 1-indexed lines and columns and
    // source maps uses 0-indexed.
    var span = sourceMap.spanFor(frame.line - 1, column - 1,
        uri: frame.uri?.toString());

    // If we can't find a source span, ignore the frame. It's probably something
    // internal that the user doesn't care about.
    if (span == null) return null;

    var sourceUrl = span.sourceUrl.toString();
    for (var root in roots) {
      if (root != null && p.url.isWithin(root, sourceUrl)) {
        var relative = p.url.relative(sourceUrl, from: root);
        if (relative.contains('dart:')) {
          sourceUrl = relative.substring(relative.indexOf('dart:'));
          break;
        }
        var packageRoot = '$root/packages';
        if (p.url.isWithin(packageRoot, sourceUrl)) {
          sourceUrl = "package:" + p.url.relative(sourceUrl, from: packageRoot);
          break;
        }
      }
    }

    if (!sourceUrl.startsWith('dart:') &&
        !sourceUrl.startsWith('package:') &&
        sourceUrl.contains('dart_sdk')) {
      // This compresses the long dart_sdk URLs if SDK source maps are missing.
      // It's no longer linkable, but neither are the properly mapped ones
      // above.
      sourceUrl = 'dart:sdk_internal';
    }

    return Frame(Uri.parse(sourceUrl), span.start.line + 1,
        span.start.column + 1, _prettifyMember(frame.member));
  }).where((frame) => frame != null));
}

final escapedPipe = '\$124';
final escapedPound = '\$35';

/// Reformats a JS member name to make it look more Dart-like.
///
/// Logic copied from build/build_web_compilers/web/stack_trace_mapper.dart.
/// TODO(https://github.com/dart-lang/sdk/issues/38869): Remove this logic when
/// DDC stack trace deobfuscation is overhauled.
String _prettifyMember(String member) {
  var last = member.lastIndexOf('.');
  if (last < 0) return member;
  var suffix = member.substring(last + 1);
  member = suffix == 'fn' ? member : suffix;
  // We avoid unescaping the entire member here due to DDC's deduping mechanism
  // introducing trailing $N.
  member = member.replaceAll(escapedPipe, '|');
  return member.contains('|') ? _prettifyExtension(member) : member;
}

/// Reformats a JS member name as an extension method invocation.
String _prettifyExtension(String member) {
  var isSetter = false;
  var pipeIndex = member.indexOf('|');
  var spaceIndex = member.indexOf(' ');
  var poundIndex = member.indexOf('escapedPound');
  if (spaceIndex >= 0) {
    // Here member is a static field or static getter/setter.
    isSetter = member.substring(0, spaceIndex) == 'set';
    member = member.substring(spaceIndex + 1, member.length);
  } else if (poundIndex >= 0) {
    // Here member is a tearoff or local property getter/setter.
    isSetter = member.substring(pipeIndex + 1, poundIndex) == 'set';
    member = member.replaceRange(pipeIndex + 1, poundIndex + 3, '');
  } else {
    var body = member.substring(pipeIndex + 1, member.length);
    if (body.startsWith('unary') || body.startsWith('\$')) {
      // Here member's an operator, so it's safe to unescape everything lazily.
      member = _unescape(member);
    }
  }
  member = member.replaceAll('|', '.');
  return isSetter ? '$member=' : member;
}

/// Unescapes a DDC-escaped JS identifier name.
///
/// Identifier names that contain illegal JS characters are escaped by DDC to a
/// decimal representation of the symbol's UTF-16 value.
/// Warning: this greedily escapes characters, so it can be unsafe in the event
/// that an escaped sequence precedes a number literal in the JS name.
String _unescape(String name) {
  return name.replaceAllMapped(
      RegExp(r'\$[0-9]+'),
      (m) =>
          String.fromCharCode(int.parse(name.substring(m.start + 1, m.end))));
}
