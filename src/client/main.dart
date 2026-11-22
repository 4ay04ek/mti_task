import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'services/api.dart';
import 'services/session.dart';
import 'tickets.dart';
import 'analytics.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ZayavkaApp());
}

class ZayavkaApp extends StatefulWidget {
  const ZayavkaApp({super.key});
  @override
  State<ZayavkaApp> createState() => _ZayavkaAppState();
}

class _ZayavkaAppState extends State<ZayavkaApp> {
  final session = Session();
  late final api = Api(session);
  Map<String, dynamic>? me;
  bool busy = true;
  String? error;
  int page = 0;

  @override
  void initState() {
    super.initState();
    restore();
  }

  Future<void> restore() async {
    try {
      if (await session.restore())
        me = Map<String, dynamic>.from(await api.get('/api/me'));
    } catch (e) {
      error = cleanError(e);
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> login() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await session.login();
      me = Map<String, dynamic>.from(await api.get('/api/me'));
    } catch (e) {
      error = cleanError(e);
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> logout() async {
    setState(() {
      me = null;
      page = 0;
      busy = true;
    });
    try {
      await session.logout();
    } catch (e) {
      error = cleanError(e);
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final admin = (me?['roles'] as List? ?? []).contains('admin');
    return MaterialApp(
      title: 'Заявка',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff126b67)),
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
      home: busy
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : me == null
          ? Scaffold(
              body: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.assignment_outlined,
                          size: 54,
                          color: Color(0xff126b67),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          'Заявка',
                          style: Theme.of(context).textTheme.headlineLarge,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Внутренние обращения организации. Создавайте заявки и следите за их выполнением.',
                        ),
                        const SizedBox(height: 28),
                        if (error != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: Text(
                              error!,
                              style: const TextStyle(color: Colors.red),
                            ),
                          ),
                        FilledButton.icon(
                          onPressed: login,
                          icon: const Icon(Icons.login),
                          label: const Text('Войти через Keycloak'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            )
          : Scaffold(
              appBar: AppBar(
                title: const Text('Заявка'),
                actions: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Center(child: Text(me!['name'] as String? ?? '')),
                  ),
                  IconButton(
                    onPressed: logout,
                    tooltip: 'Выйти',
                    icon: const Icon(Icons.logout),
                  ),
                ],
              ),
              body: page == 0
                  ? TicketsPage(api: api, me: me!)
                  : AnalyticsPage(api: api),
              bottomNavigationBar: admin
                  ? NavigationBar(
                      selectedIndex: page,
                      onDestinationSelected: (value) =>
                          setState(() => page = value),
                      destinations: const [
                        NavigationDestination(
                          icon: Icon(Icons.assignment_outlined),
                          label: 'Заявки',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.bar_chart),
                          label: 'Аналитика',
                        ),
                      ],
                    )
                  : null,
            ),
    );
  }
}

String cleanError(Object error) {
  if (error is PlatformException) {
    return 'Не удалось выполнить действие. Повторите попытку.';
  }
  return error.toString().replaceFirst('Exception: ', '');
}

const categories = {
  'it': 'IT',
  'equipment': 'Оборудование',
  'household': 'Хозяйственные вопросы',
};
const statuses = {
  'new': 'Новая',
  'in_progress': 'В работе',
  'completed': 'Выполнена',
};

String displayDate(dynamic value) {
  final date = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
  if (date == null) return '—';
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(date.day)}.${two(date.month)}.${date.year} ${two(date.hour)}:${two(date.minute)}';
}

void showError(BuildContext context, Object error) =>
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(cleanError(error))));
