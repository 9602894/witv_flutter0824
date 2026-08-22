class EpgProgram {
  final String title;
  final String description;
  final DateTime start;
  final DateTime stop;

  EpgProgram({
    required this.title,
    required this.description,
    required this.start,
    required this.stop,
  });

  factory EpgProgram.fromJson(Map<String, dynamic> json) => EpgProgram(
        title: json['title'] ?? '',
        description: json['description'] ?? '',
        start: DateTime.parse(json['start']),
        stop: DateTime.parse(json['stop']),
      );

  Map<String, dynamic> toJson() => {
        'title': title,
        'description': description,
        'start': start.toIso8601String(),
        'stop': stop.toIso8601String(),
      };
}
