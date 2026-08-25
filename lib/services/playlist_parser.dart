import 'package:dio/dio.dart';
import 'dart:io';
import '../models/channel.dart';
import 'log_service.dart';
import 'settings_service.dart';

class PlaylistParser {
  static Future<Map<String, List<Channel>>> parseFromUrl(String url) async {
    await LogService.write('开始解析播放列表: $url');
    try {
      final response = await Dio().get(url);
      final content = response.data as String;
      await LogService.write('下载成功，内容长度: ${content.length}');
      return parseFromString(content);
    } catch (e, stack) {
      await LogService.writeCrashLog(e, stack);
      rethrow;
    }
  }

  static Map<String, List<Channel>> parseFromString(String content) {
    final lines = content.split('\n');
    final Map<String, List<Channel>> groupMap = {};
    String currentGroup = '默认分组';
    int autoChannelNumber = 1;

    for (var i = 0; i < lines.length; i++) {
      String line = lines[i].trim();
      if (line.startsWith('#EXTM3U')) continue;

      if (line.startsWith('#EXTINF:')) {
        final groupMatch = RegExp(r'group-title="([^"]*)"').firstMatch(line);
        final logoMatch = RegExp(r'tvg-logo="([^"]*)"').firstMatch(line);
        final chnoMatch = RegExp(r'tvg-chno="([^"]*)"').firstMatch(line);
        final name = line.split(',').last.trim();
        final group = groupMatch?.group(1) ?? '默认分组';
        final logo = logoMatch?.group(1);
        int? channelNumber;
        if (chnoMatch != null) {
          final chnoStr = chnoMatch.group(1);
          if (chnoStr != null && chnoStr.isNotEmpty) {
            channelNumber = int.tryParse(chnoStr);
          }
        }
        // 如果没有预设频道号，自动按顺序分配
        if (channelNumber == null) {
          channelNumber = autoChannelNumber++;
        } else {
          // 如果有预设频道号，确保后续自动编号从这个号之后开始
          autoChannelNumber = channelNumber + 1;
        }

        if (i + 1 < lines.length) {
          String urlLine = lines[i + 1].trim();
          if (!urlLine.startsWith('#') && urlLine.isNotEmpty) {
            groupMap.putIfAbsent(group, () => []);
            groupMap[group]!.add(Channel(
              name: name,
              url: urlLine,
              group: group,
              logoUrl: logo,
              number: channelNumber,
            ));
          }
        }
      } else if (line.contains('#genre#')) {
        // 修复：去除可能残留的逗号
        currentGroup = line.replaceAll(RegExp(r',?\s*#genre#\s*'), '').trim();
        groupMap.putIfAbsent(currentGroup, () => []);
      } else if (line.isNotEmpty && !line.startsWith('#')) {
        final parts = line.split(',');
        if (parts.length >= 2) {
          final name = parts[0].trim();
          final url = parts[1].trim();
          groupMap.putIfAbsent(currentGroup, () => []);
          groupMap[currentGroup]!.add(Channel(
            name: name,
            url: url,
            group: currentGroup,
            number: autoChannelNumber++,
          ));
        }
      }
    }
    return groupMap;
  }

  static Future<File> getCacheFile(String url, String name) async {
    final cacheDir = await SettingsService.getCacheDir();
    final hash = url.hashCode.toRadixString(16).padLeft(8, '0');
    final extension = _getExtension(url);
    final fileName = 'playlist_$hash.$extension';
    return File('${cacheDir.path}/$fileName');
  }

  static String _getExtension(String url) {
    final parts = url.split('.');
    final ext = parts.last.split('?')[0];
    if (ext == 'm3u' || ext == 'm3u8' || ext == 'txt') {
      return ext;
    }
    return 'm3u';
  }

  static Future<void> saveCache(Map<String, List<Channel>> groupMap, String url, String name) async {
    final file = await getCacheFile(url, name);
    final content = _serializeToM3U(groupMap);
    await file.writeAsString(content);
    await LogService.write('缓存已保存: ${file.path}');
  }

  static String _serializeToM3U(Map<String, List<Channel>> groupMap) {
    StringBuffer sb = StringBuffer();
    sb.writeln('#EXTM3U');
    for (var entry in groupMap.entries) {
      final group = entry.key;
      for (var ch in entry.value) {
        final chno = ch.number != null ? ' tvg-chno="${ch.number}"' : '';
        sb.writeln('#EXTINF:-1 group-title="$group" tvg-logo="${ch.logoUrl ?? ''}"$chno,${ch.name}');
        sb.writeln(ch.url);
      }
    }
    return sb.toString();
  }
}
