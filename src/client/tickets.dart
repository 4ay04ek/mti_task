import 'package:material_ui/material_ui.dart';

import 'main.dart';
import 'services/api.dart';
import 'services/export.dart';
import 'ticket_detail.dart';

class TicketsPage extends StatefulWidget {
  const TicketsPage({super.key, required this.api, required this.me});
  final Api api;
  final Map<String, dynamic> me;
  @override
  State<TicketsPage> createState() => _TicketsPageState();
}

class _TicketsPageState extends State<TicketsPage> {
  final search = TextEditingController();
  String status = '', category = '', assignee = '';
  late Future<List<dynamic>> tickets;
  List<dynamic> users = [];
  bool exporting = false;
  bool get admin => (widget.me['roles'] as List).contains('admin');
  Map<String, String> get filters => {
    if (search.text.trim().isNotEmpty) 'q': search.text.trim(),
    if (status.isNotEmpty) 'status': status,
    if (category.isNotEmpty) 'category': category,
    if (assignee.isNotEmpty) 'assignee_id': assignee,
  };

  @override
  void initState() {
    super.initState();
    tickets = load();
    if (admin) loadUsers();
  }

  Future<void> loadUsers() async {
    try {
      final result = List<dynamic>.from(await widget.api.get('/api/users'));
      if (mounted) setState(() => users = result);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<List<dynamic>> load() async =>
      List<dynamic>.from(await widget.api.get('/api/tickets', filters));
  void refresh() => setState(() => tickets = load());
  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> open(Map<String, dynamic> ticket) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TicketDetail(
          api: widget.api,
          me: widget.me,
          ticketId: ticket['id'] as int,
        ),
      ),
    );
    if (mounted) refresh();
  }

  Future<void> create() async {
    final created = await showDialog<bool>(
      context: context,
      builder: (_) => NewTicket(api: widget.api),
    );
    if (created == true && mounted) refresh();
  }

  Future<void> export(BuildContext buttonContext) async {
    setState(() => exporting = true);
    try {
      final bytes = await widget.api.csv(filters);
      if (!mounted || !buttonContext.mounted) return;
      final box = buttonContext.findRenderObject() as RenderBox;
      await saveCsv(bytes, box.localToGlobal(Offset.zero) & box.size);
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() => exporting = false);
  }

  Widget dropdown(
    String value,
    String label,
    Map<String, String> values,
    ValueChanged<String> changed,
  ) => SizedBox(
    width: 210,
    child: DropdownButtonFormField<String>(
      initialValue: value,
      decoration: InputDecoration(labelText: label),
      isExpanded: true,
      items: [
        const DropdownMenuItem(value: '', child: Text('Все')),
        ...values.entries.map(
          (e) => DropdownMenuItem(
            value: e.key,
            child: Text(e.value, overflow: TextOverflow.ellipsis),
          ),
        ),
      ],
      onChanged: (value) {
        changed(value ?? '');
        refresh();
      },
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    floatingActionButton: FloatingActionButton.extended(
      onPressed: create,
      icon: const Icon(Icons.add),
      label: const Text('Новая заявка'),
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 280,
                child: TextField(
                  controller: search,
                  onSubmitted: (_) => refresh(),
                  decoration: InputDecoration(
                    labelText: 'Поиск по тексту',
                    suffixIcon: IconButton(
                      onPressed: refresh,
                      icon: const Icon(Icons.search),
                    ),
                  ),
                ),
              ),
              dropdown(status, 'Статус', statuses, (v) => status = v),
              dropdown(category, 'Категория', categories, (v) => category = v),
              if (admin)
                dropdown(assignee, 'Исполнитель', {
                  for (final user in users)
                    user['id'] as String: user['name'] as String,
                }, (v) => assignee = v),
              IconButton(
                onPressed: refresh,
                tooltip: 'Обновить',
                icon: const Icon(Icons.refresh),
              ),
              Builder(
                builder: (buttonContext) => OutlinedButton.icon(
                  onPressed: exporting ? null : () => export(buttonContext),
                  icon: const Icon(Icons.download),
                  label: const Text('CSV'),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<List<dynamic>>(
            future: tickets,
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
                          onPressed: refresh,
                          child: const Text('Повторить'),
                        ),
                      ],
                    ),
                  ),
                );
              if (snapshot.data!.isEmpty)
                return const Center(child: Text('Заявок пока нет'));
              return RefreshIndicator(
                onRefresh: () async {
                  refresh();
                  await tickets;
                },
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                  itemCount: snapshot.data!.length,
                  separatorBuilder: (_, index) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final item = Map<String, dynamic>.from(
                      snapshot.data![index],
                    );
                    final overdue =
                        item['status'] != 'completed' &&
                        item['due_at'] != null &&
                        DateTime.parse(item['due_at']).isBefore(DateTime.now());
                    return Card(
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 10,
                        ),
                        title: Text(
                          '#${item['id']} · ${item['title']}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            '${categories[item['category']]} · ${statuses[item['status']]}\nСоздана ${displayDate(item['created_at'])}${overdue ? '\nСрок истёк' : ''}',
                            style: TextStyle(
                              color: overdue ? Colors.red.shade700 : null,
                            ),
                          ),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => open(item),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ),
      ],
    ),
  );
}

class NewTicket extends StatefulWidget {
  const NewTicket({super.key, required this.api});
  final Api api;
  @override
  State<NewTicket> createState() => _NewTicketState();
}

class _NewTicketState extends State<NewTicket> {
  final form = GlobalKey<FormState>();
  final title = TextEditingController(), description = TextEditingController();
  String category = 'it';
  String? hint;
  bool busy = false;
  @override
  void dispose() {
    title.dispose();
    description.dispose();
    super.dispose();
  }

  Future<void> suggest() async {
    if (!form.currentState!.validate()) return;
    setState(() => busy = true);
    try {
      final result = await widget.api.post('/classification/classify', {
        'title': title.text.trim(),
        'description': description.text.trim(),
      });
      if (!mounted) return;
      setState(() {
        if (result['available'] == true &&
            categories.containsKey(result['category'])) {
          category = result['category'];
          hint =
              'Предложена категория «${categories[category]}». Подтвердите её или выберите другую.';
        } else {
          hint = 'Модель пока недоступна. Выберите категорию вручную.';
        }
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> save() async {
    if (!form.currentState!.validate()) return;
    setState(() => busy = true);
    try {
      await widget.api.post('/api/tickets', {
        'title': title.text.trim(),
        'description': description.text.trim(),
        'category': category,
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => busy = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Новая заявка'),
    content: SizedBox(
      width: 500,
      child: SingleChildScrollView(
        child: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                controller: title,
                maxLength: 200,
                decoration: const InputDecoration(labelText: 'Заголовок'),
                validator: (v) =>
                    v!.trim().isEmpty ? 'Введите заголовок' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: description,
                maxLines: 4,
                maxLength: 5000,
                decoration: const InputDecoration(labelText: 'Описание'),
                validator: (v) => v!.trim().isEmpty ? 'Опишите проблему' : null,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: busy ? null : suggest,
                icon: const Icon(Icons.auto_awesome),
                label: const Text('Предложить категорию'),
              ),
              if (hint != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(hint!),
                ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: ValueKey(category),
                initialValue: category,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Категория'),
                items: categories.entries
                    .map(
                      (e) =>
                          DropdownMenuItem(value: e.key, child: Text(e.value)),
                    )
                    .toList(),
                onChanged: busy ? null : (v) => setState(() => category = v!),
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: busy ? null : save,
        child: Text(busy ? 'Подождите…' : 'Создать'),
      ),
    ],
  );
}
