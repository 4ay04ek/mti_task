import 'package:material_ui/material_ui.dart';

import 'main.dart';
import 'services/api.dart';

class TicketDetail extends StatefulWidget {
  const TicketDetail({
    super.key,
    required this.api,
    required this.me,
    required this.ticketId,
  });
  final Api api;
  final Map<String, dynamic> me;
  final int ticketId;
  @override
  State<TicketDetail> createState() => _TicketDetailState();
}

class _TicketDetailState extends State<TicketDetail> {
  late Future<void> loading;
  Map<String, dynamic> ticket = {};
  List<dynamic> history = [], users = [];
  String category = 'it', assignee = '';
  DateTime? due;
  bool busy = false;
  bool get admin => (widget.me['roles'] as List).contains('admin');

  @override
  void initState() {
    super.initState();
    loading = load();
  }

  Future<void> load() async {
    final result = await Future.wait([
      widget.api.get('/api/tickets/${widget.ticketId}'),
      widget.api.get('/api/tickets/${widget.ticketId}/history'),
      if (admin) widget.api.get('/api/users'),
    ]);
    ticket = Map<String, dynamic>.from(result[0]);
    history = List<dynamic>.from(result[1]);
    if (admin) users = List<dynamic>.from(result[2]);
    category = ticket['category'];
    assignee = ticket['assignee_id'] ?? '';
    due = DateTime.tryParse(ticket['due_at'] ?? '')?.toLocal();
  }

  Future<void> patch(Map<String, dynamic> body) async {
    setState(() => busy = true);
    try {
      await widget.api.patch('/api/tickets/${widget.ticketId}', body);
      await load();
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Заявка обновлена')));
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> complete() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Результат выполнения'),
        content: SizedBox(
          width: 440,
          child: TextField(
            controller: controller,
            maxLines: 4,
            maxLength: 5000,
            decoration: const InputDecoration(labelText: 'Что сделано'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty)
                Navigator.pop(context, controller.text.trim());
            },
            child: const Text('Завершить'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result != null) await patch({'status': 'completed', 'result': result});
  }

  Future<void> chooseDate() async {
    final now = DateTime.now();
    final chosen = await showDatePicker(
      context: context,
      initialDate: due ?? now,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 5),
    );
    if (chosen != null && mounted)
      setState(
        () => due = DateTime(chosen.year, chosen.month, chosen.day, 23, 59),
      );
  }

  String value(String field, dynamic value) {
    if (value == null || value == '') return '—';
    if (field == 'category') return categories[value] ?? value.toString();
    if (field == 'status') return statuses[value] ?? value.toString();
    if (field == 'due_at') return displayDate(value);
    if (field == 'category_checked')
      return value == true ? 'Подтверждена' : 'Не подтверждена';
    if (field == 'assignee_id') {
      for (final user in users) {
        if (user['id'] == value) return user['name'];
      }
      return value == widget.me['id'] ? widget.me['name'] : 'Назначен';
    }
    return value.toString();
  }

  Widget info(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 3),
        SelectableText(value),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Заявка #${widget.ticketId}')),
    body: FutureBuilder<void>(
      future: loading,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done)
          return const Center(child: CircularProgressIndicator());
        if (snapshot.hasError)
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(cleanError(snapshot.error!)),
                  const SizedBox(height: 16),
                  OutlinedButton(
                    onPressed: () => setState(() => loading = load()),
                    child: const Text('Повторить'),
                  ),
                ],
              ),
            ),
          );
        final canWork =
            admin ||
            ((widget.me['roles'] as List).contains('executor') &&
                ticket['assignee_id'] == widget.me['id']);
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 850),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  ticket['title'],
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [
                    Chip(label: Text(statuses[ticket['status']]!)),
                    Chip(label: Text(categories[ticket['category']]!)),
                  ],
                ),
                const SizedBox(height: 12),
                SelectableText(ticket['description']),
                const Divider(height: 32),
                info('Создана', displayDate(ticket['created_at'])),
                info(
                  'Исполнитель',
                  value('assignee_id', ticket['assignee_id']),
                ),
                info('Срок', displayDate(ticket['due_at'])),
                if (ticket['result'] != null)
                  info('Результат', ticket['result']),
                if (ticket['completed_at'] != null)
                  info('Выполнена', displayDate(ticket['completed_at'])),
                if (admin) ...[
                  const Divider(height: 32),
                  Text(
                    ticket['status'] == 'completed'
                        ? 'Проверка категории'
                        : 'Назначение и категория',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    key: ValueKey('category-$category'),
                    initialValue: category,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Категория'),
                    items: categories.entries
                        .map(
                          (e) => DropdownMenuItem(
                            value: e.key,
                            child: Text(e.value),
                          ),
                        )
                        .toList(),
                    onChanged: busy
                        ? null
                        : (v) => setState(() => category = v!),
                  ),
                  if (ticket['status'] != 'completed') ...[
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      key: ValueKey('assignee-$assignee'),
                      initialValue: assignee,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Исполнитель',
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: '',
                          child: Text('Не назначен'),
                        ),
                        ...users.map(
                          (user) => DropdownMenuItem<String>(
                            value: user['id'],
                            child: Text(user['name']),
                          ),
                        ),
                        if (assignee.isNotEmpty &&
                            !users.any((u) => u['id'] == assignee))
                          DropdownMenuItem(
                            value: assignee,
                            child: const Text(
                              'Назначенный исполнитель недоступен',
                            ),
                          ),
                      ],
                      onChanged: busy
                          ? null
                          : (v) => setState(() => assignee = v!),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        OutlinedButton.icon(
                          onPressed: busy ? null : chooseDate,
                          icon: const Icon(Icons.event),
                          label: Text(
                            due == null
                                ? 'Установить срок'
                                : displayDate(due!.toIso8601String()),
                          ),
                        ),
                        if (due != null)
                          TextButton(
                            onPressed: busy
                                ? null
                                : () => setState(() => due = null),
                            child: const Text('Убрать срок'),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  const Text(
                    'Сохранение подтверждает категорию для обучения модели.',
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: busy
                        ? null
                        : () => patch({
                            'category': category,
                            if (ticket['status'] != 'completed')
                              'assignee_id': assignee.isEmpty ? null : assignee,
                            if (ticket['status'] != 'completed')
                              'due_at': due?.toUtc().toIso8601String(),
                          }),
                    child: const Text('Сохранить и подтвердить категорию'),
                  ),
                ],
                if (canWork && ticket['status'] != 'completed') ...[
                  const SizedBox(height: 20),
                  if (ticket['status'] == 'new')
                    FilledButton.icon(
                      onPressed: busy || ticket['assignee_id'] == null
                          ? null
                          : () => patch({'status': 'in_progress'}),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Принять в работу'),
                    ),
                  if (ticket['status'] == 'in_progress')
                    FilledButton.icon(
                      onPressed: busy ? null : complete,
                      icon: const Icon(Icons.check),
                      label: const Text('Отметить выполнение'),
                    ),
                ],
                const Divider(height: 40),
                Text(
                  'История изменений',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                ...history.map((entry) {
                  const fields = {
                    'status': 'Статус',
                    'category': 'Категория',
                    'assignee_id': 'Исполнитель',
                    'due_at': 'Срок',
                    'result': 'Результат',
                    'category_checked': 'Проверка категории',
                  };
                  final changes = Map<String, dynamic>.from(
                    entry['changes'] as Map,
                  );
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${entry['actor_name'] ?? entry['actor_id']} · ${displayDate(entry['created_at'])}',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          const SizedBox(height: 8),
                          ...changes.entries.map(
                            (change) => Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(
                                '${fields[change.key] ?? change.key}: ${value(change.key, change.value['from'])} → ${value(change.key, change.value['to'])}',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
        );
      },
    ),
  );
}
