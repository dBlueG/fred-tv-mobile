import 'package:flutter/material.dart';
import 'package:open_tv/confirm_delete.dart';
import 'package:open_tv/error.dart';
import 'package:open_tv/favorite_lists_dialog.dart';
import 'package:open_tv/models/favorite_list.dart';
import 'package:open_tv/native_bridge.dart';
import 'package:open_tv/task_service.dart';

// Chip row on the Favorites screen: "All", one chip per list, and controls to
// create, rename and delete lists. A null selection means all favorites.
class FavoriteListBar extends StatefulWidget {
  final int? selectedId;
  final ValueChanged<int?> onSelected;

  const FavoriteListBar({
    super.key,
    required this.selectedId,
    required this.onSelected,
  });

  @override
  State<FavoriteListBar> createState() => _FavoriteListBarState();
}

class _FavoriteListBarState extends State<FavoriteListBar> {
  List<FavoriteList> _lists = [];

  @override
  void initState() {
    super.initState();
    TaskService.instance.favoriteListsVersion.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    TaskService.instance.favoriteListsVersion.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final result = await Error.tryAsyncNoLoading(
      () => NativeBridge.instance.getFavoriteLists(),
    );
    if (!mounted || result.data == null) return;
    setState(() => _lists = result.data!);
    final selected = widget.selectedId;
    if (selected != null && !_lists.any((l) => l.id == selected)) {
      widget.onSelected(null);
    }
  }

  Future<void> _create() async {
    final list = await promptCreateFavoriteList(context, _lists);
    if (list != null) widget.onSelected(list.id);
  }

  Future<void> _rename(FavoriteList list) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => FavoriteListNameDialog(
        title: "Rename list",
        existing: _lists,
        initialName: list.name,
        editingId: list.id,
      ),
    );
    if (name == null) return;
    await Error.tryAsyncNoLoading(
      () => TaskService.instance.renameFavoriteList(list.id, name),
    );
  }

  void _delete(FavoriteList list) {
    showDialog(
      context: context,
      builder: (_) => ConfirmDelete(
        type: "the favorite list",
        name: list.name,
        confirm: () async {
          await Error.tryAsyncNoLoading(
            () => TaskService.instance.deleteFavoriteList(list.id),
          );
        },
      ),
    );
  }

  Future<void> _showListActions(FavoriteList list) async {
    final action = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(list.name),
        children: [
          ListTile(
            autofocus: true,
            leading: const Icon(Icons.edit),
            title: const Text("Rename"),
            onTap: () => Navigator.of(context).pop("rename"),
          ),
          ListTile(
            leading: const Icon(Icons.delete),
            title: const Text("Delete"),
            subtitle: const Text("Channels stay in your favorites"),
            onTap: () => Navigator.of(context).pop("delete"),
          ),
        ],
      ),
    );
    switch (action) {
      case "rename":
        await _rename(list);
      case "delete":
        _delete(list);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = _lists.where((l) => l.id == widget.selectedId).firstOrNull;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        spacing: 8,
        children: [
          ChoiceChip(
            label: const Text("All"),
            avatar: const Icon(Icons.star, color: Colors.amber),
            showCheckmark: false,
            selected: widget.selectedId == null,
            onSelected: (_) => widget.onSelected(null),
          ),
          for (final list in _lists)
            GestureDetector(
              onLongPress: () => _showListActions(list),
              child: ChoiceChip(
                label: Text(list.name),
                showCheckmark: false,
                selected: list.id == widget.selectedId,
                onSelected: (_) => widget.onSelected(list.id),
              ),
            ),
          ActionChip(
            avatar: const Icon(Icons.add),
            label: const Text("New list"),
            onPressed: _create,
          ),
          if (selected != null)
            IconButton(
              tooltip: "Edit list",
              icon: const Icon(Icons.more_vert),
              onPressed: () => _showListActions(selected),
            ),
        ],
      ),
    );
  }
}
