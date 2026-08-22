class EpgProgram {
  final String title;
  final DateTime start;
  final DateTime end;
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
}
