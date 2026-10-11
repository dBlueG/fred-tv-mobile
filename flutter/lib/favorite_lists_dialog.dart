import 'package:flutter/material.dart';
import 'package:open_tv/error.dart';
import 'package:open_tv/models/favorite_list.dart';
import 'package:open_tv/task_service.dart';

class FavoriteChoice {
  final bool favorite;
  final List<int> listIds;

  const FavoriteChoice({required this.favorite, this.listIds = const []});
}

// Asks for a list name, rejecting empty names and names already in use.
class FavoriteListNameDialog extends StatefulWidget {
  final String title;
  final String? initialName;
  final List<FavoriteList> existing;
  final int? editingId;

  const FavoriteListNameDialog({
    super.key,
    required this.title,
    required this.existing,
    this.initialName,
    this.editingId,
  });

  @override
  State<FavoriteListNameDialog> createState() => _FavoriteListNameDialogState();
}

class _FavoriteListNameDialogState extends State<FavoriteListNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialName,
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    final taken = widget.existing.any(
      (l) =>
          l.id != widget.editingId && l.name.toLowerCase() == name.toLowerCase(),
    );
    if (name.isEmpty || taken) {
      setState(() {
        _error = name.isEmpty
            ? "Name can't be empty"
            : "A list with this name already exists";
      });
      return;
    }
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 100,
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          hintText: "e.g. News, Sports, Movies",
          errorText: _error,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text("Cancel"),
        ),
        TextButton(onPressed: _submit, child: const Text("Save")),
      ],
    );
  }
}

// Prompts for a name and creates the list. Returns null if cancelled or failed.
Future<FavoriteList?> promptCreateFavoriteList(
  BuildContext context,
  List<FavoriteList> existing,
) async {
  final name = await showDialog<String>(
    context: context,
    builder: (_) =>
        FavoriteListNameDialog(title: "New favorite list", existing: existing),
  );
  if (name == null) return null;
  final result = await Error.tryAsyncNoLoading(
    () => TaskService.instance.createFavoriteList(name),
  );
  return result.data;
}

// Lets the user pick which favorite lists a channel belongs to.
class FavoriteListsDialog extends StatefulWidget {
  final String channelName;
  final bool isFavorite;
  final List<FavoriteList> lists;
  final Set<int> selected;

  const FavoriteListsDialog({
    super.key,
    required this.channelName,
    required this.isFavorite,
    required this.lists,
    required this.selected,
  });

  @override
  State<FavoriteListsDialog> createState() => _FavoriteListsDialogState();
}

class _FavoriteListsDialogState extends State<FavoriteListsDialog> {
  late final List<FavoriteList> _lists = [...widget.lists];
  late final Set<int> _selected = {...widget.selected};

  Future<void> _createList() async {
    final list = await promptCreateFavoriteList(context, _lists);
    if (list == null || !mounted) return;
    setState(() {
      _lists.add(list);
      _selected.add(list.id);
    });
  }

  void _save() {
    Navigator.of(context).pop(
      FavoriteChoice(
        favorite: true,
        listIds: _lists
            .where((l) => _selected.contains(l.id))
            .map((l) => l.id)
            .toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.isFavorite ? "Favorite lists" : "Add to favorites"),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  widget.channelName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.star, color: Colors.amber),
                title: Text("All favorites"),
                subtitle: Text("Always included"),
              ),
              for (final (index, list) in _lists.indexed)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  autofocus: index == 0,
                  value: _selected.contains(list.id),
                  title: Text(list.name),
                  onChanged: (checked) => setState(() {
                    if (checked == true) {
                      _selected.add(list.id);
                    } else {
                      _selected.remove(list.id);
                    }
                  }),
                ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.add),
                title: const Text("New list"),
                onTap: _createList,
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (widget.isFavorite)
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(
              context,
            ).pop(const FavoriteChoice(favorite: false)),
            child: const Text("Remove"),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text("Cancel"),
        ),
        TextButton(onPressed: _save, child: const Text("Save")),
      ],
    );
  }
}
