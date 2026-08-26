import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class GroupList extends StatefulWidget {
  final List<String> groups;
  final String? selectedGroup;
  final ValueChanged<String> onSelect;
  final bool enableRemoteControl;

  const GroupList({
    Key? key,
    required this.groups,
    this.selectedGroup,
    required this.onSelect,
    this.enableRemoteControl = true,
  }) : super(key: key);

  @override
  State<GroupList> createState() => _GroupListState();
}

class _GroupListState extends State<GroupList> {
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    if (widget.enableRemoteControl) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _focusNode.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _handleKey(RawKeyEvent event) {
    if (!widget.enableRemoteControl) return;
    if (event is! RawKeyDownEvent) return;
    final key = event.logicalKey;

    final currentIndex = widget.groups.indexOf(widget.selectedGroup ?? '');
    if (key == LogicalKeyboardKey.arrowUp) {
      final newIndex = currentIndex > 0 ? currentIndex - 1 : widget.groups.length - 1;
      if (widget.groups.isNotEmpty) {
        widget.onSelect(widget.groups[newIndex]);
        _scrollToIndex(newIndex);
      }
    } else if (key == LogicalKeyboardKey.arrowDown) {
      final newIndex = currentIndex < widget.groups.length - 1 ? currentIndex + 1 : 0;
      if (widget.groups.isNotEmpty) {
        widget.onSelect(widget.groups[newIndex]);
        _scrollToIndex(newIndex);
      }
    }
  }

  void _scrollToIndex(int index) {
    if (!_scrollController.hasClients) return;
    final itemHeight = 56.0;
    final offset = index * itemHeight;
    _scrollController.animateTo(
      offset.clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return RawKeyboardListener(
      focusNode: _focusNode,
      onKey: _handleKey,
      child: Container(
        color: Colors.black.withOpacity(0.7),
        child: ListView.builder(
          controller: _scrollController,
          itemCount: widget.groups.length,
          itemBuilder: (context, index) {
            final group = widget.groups[index];
            final isSelected = group == widget.selectedGroup;
            return ListTile(
              dense: true,
              selected: isSelected,
              selectedTileColor: Colors.blue.withOpacity(0.4),
              tileColor: isSelected ? Colors.blue.withOpacity(0.3) : Colors.transparent,
              title: Text(
                group,
                style: TextStyle(
                  color: isSelected ? Colors.yellow : Colors.white,
                  fontSize: 14,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
              onTap: () => widget.onSelect(group),
            );
          },
        ),
      ),
    );
  }
}
