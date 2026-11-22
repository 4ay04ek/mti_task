import 'dart:math';

import 'package:material_ui/material_ui.dart';

import 'main.dart';
import 'services/api.dart';

class AnalyticsPage extends StatefulWidget {
  const AnalyticsPage({super.key, required this.api});
  final Api api;
  @override
  State<AnalyticsPage> createState() => _AnalyticsPageState();
}

class _AnalyticsPageState extends State<AnalyticsPage> {
  DateTimeRange? period;
  late Future<Map<String, dynamic>> data;
  bool training = false;
  String? trainingResult;

  @override
  void initState() {
    super.initState();
    data = load();
  }

  String day(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  Future<Map<String, dynamic>> load() async => Map<String, dynamic>.from(
    await widget.api.get('/analytics', {
      if (period != null) 'date_from': day(period!.start),
      if (period != null) 'date_to': day(period!.end),
    }),
  );

  Future<void> selectPeriod() async {
    final chosen = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 366)),
      initialDateRange: period,
    );
    if (chosen != null && mounted)
      setState(() {
        period = chosen;
        data = load();
      });
  }

  Future<void> train() async {
    setState(() {
      training = true;
      trainingResult = null;
    });
    try {
      final result = await widget.api.post('/classification/train', {});
      if (mounted)
        setState(
          () => trainingResult =
              'Модель обучена: ${result['samples']} заявок, macro-F1 ${(result['macro_f1'] as num).toStringAsFixed(3)}.',
        );
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() => training = false);
  }

  Widget metric(String label, String value) => SizedBox(
    width: 230,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label),
            const SizedBox(height: 12),
            Text(value, style: Theme.of(context).textTheme.headlineMedium),
          ],
        ),
      ),
    ),
  );

  Widget bars(
    String title,
    Map<String, String> labels,
    Map<String, dynamic> counts,
  ) {
    final maximum = max(
      1,
      counts.values.fold<num>(0, (a, b) => max(a, b as num)),
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 20),
            ...labels.entries.map(
              (entry) => Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text(entry.value)),
                        Text('${counts[entry.key] ?? 0}'),
                      ],
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: (counts[entry.key] as num? ?? 0) / maximum,
                      minHeight: 12,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1000),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Аналитика', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              OutlinedButton.icon(
                onPressed: selectPeriod,
                icon: const Icon(Icons.date_range),
                label: Text(
                  period == null
                      ? 'Весь период'
                      : '${day(period!.start)} — ${day(period!.end)}',
                ),
              ),
              if (period != null)
                TextButton(
                  onPressed: () => setState(() {
                    period = null;
                    data = load();
                  }),
                  child: const Text('Сбросить период'),
                ),
              IconButton(
                onPressed: () => setState(() => data = load()),
                tooltip: 'Обновить',
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 16),
          FutureBuilder<Map<String, dynamic>>(
            future: data,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done)
                return const Padding(
                  padding: EdgeInsets.all(36),
                  child: Center(child: CircularProgressIndicator()),
                );
              if (snapshot.hasError)
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(cleanError(snapshot.error!)),
                );
              final result = snapshot.data!;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      metric('Всего заявок', '${result['total']}'),
                      metric('Просрочено', '${result['overdue']}'),
                      metric(
                        'Среднее время выполнения',
                        result['average_completion_hours'] == null
                            ? 'Нет данных'
                            : '${(result['average_completion_hours'] as num).toStringAsFixed(1)} ч',
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  bars(
                    'Статусы',
                    statuses,
                    Map<String, dynamic>.from(result['statuses']),
                  ),
                  const SizedBox(height: 12),
                  bars(
                    'Категории',
                    categories,
                    Map<String, dynamic>.from(result['categories']),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Последнее обновление: ${displayDate(result['updated_at'])}. Аналитика обновляется по событиям и может отставать от реестра.',
                  ),
                ],
              );
            },
          ),
          const Divider(height: 40),
          Text(
            'Классификация обращений',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          const Text(
            'Обучение использует выполненные заявки с подтверждённой администратором категорией. Требуется минимум три примера каждой из представленных категорий и минимум две категории.',
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: training ? null : train,
              icon: const Icon(Icons.model_training),
              label: Text(training ? 'Обучение…' : 'Обучить модель'),
            ),
          ),
          if (trainingResult != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(trainingResult!),
            ),
        ],
      ),
    ),
  );
}
