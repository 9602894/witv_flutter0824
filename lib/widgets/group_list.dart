import 'package:flutter/material.dart';

class GroupList extends StatelessWidget {
  final List<String> groups;
  final String? selectedGroup;
  final ValueChanged<String> onSelect;

  const GroupList({
    Key? key,
    required this.groups,
    this.selectedGroup,
    required this.onSelect,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: groups.length,
      itemBuilder: (context, index) {
        final group = groups[index];
        final isSelected = group == selectedGroup;
        return InkWell(
          onTap: () => onSelect(group),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: isSelected ? Colors.blue.withOpacity(0.3) : Colors.transparent,
              border: Border(
                left: BorderSide(
                  color: isSelected ? Colors.yellow : Colors.transparent,
                  width: 3,
                ),
              ),
            ),
            child: Text(
              group,
              style: TextStyle(
                color: isSelected ? Colors.yellow : Colors.white,
                fontSize: 14,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
        );
      },
    );
  }
}

