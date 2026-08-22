class EpgProgram {
  final String title;
  final DateTime start;   // 统一存储为东八区本地时间
  final DateTime end;     // 统一存储为东八区本地时间
  final String? desc;

  EpgProgram({
    required this.title,
    required this.start,
    required this.end,
    this.desc,
  });

  Map<String, dynamic> toJson() => {
    'title': title,
    'start': start.millisecondsSinceEpoch,
    'end': end.millisecondsSinceEpoch,
    'desc': desc,
  };

  factory EpgProgram.fromJson(Map<String, dynamic> json) => EpgProgram(
    title: json['title'] as String,
    start: DateTime.fromMillisecondsSinceEpoch(json['start'] as int),
    end: DateTime.fromMillisecondsSinceEpoch(json['end'] as int),
    desc: json['desc'] as String?,
  );

  /// 判断当前节目是否正在播放（传入东八区当前时间）
  bool isPlaying(DateTime nowCST) {
    return nowCST.isAfter(start) && nowCST.isBefore(end);
  }

  /// 获取进度百分比（0.0 ~ 1.0）
  double progress(DateTime nowCST) {
    if (nowCST.isBefore(start)) return 0.0;
    if (nowCST.isAfter(end)) return 1.0;
    final total = end.difference(start).inSeconds;
    final passed = nowCST.difference(start).inSeconds;
    return passed / total;
  }
}
