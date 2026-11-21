import 'package:flutter/material.dart';

import 'demos/ink_splash_theme/ink_splash_theme_demo.dart';

void main() {
  runApp(const MyApp());
}

/// One entry per demo. Each demo lives in its own folder under lib/demos/.
class DemoEntry {
  const DemoEntry(this.title, this.description, this.builder);
  final String title;
  final String description;
  final WidgetBuilder builder;
}

final demos = <DemoEntry>[
  DemoEntry(
    'Ink Splash Theme',
    'Dark / light mode switch with a spreading ink reveal',
    (_) => const InkSplashThemeDemo(),
  ),
];

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'UI Demo',
      theme: ThemeData(colorScheme: .fromSeed(seedColor: Colors.deepPurple)),
      home: const DemoListPage(),
    );
  }
}

class DemoListPage extends StatelessWidget {
  const DemoListPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('UI Demos')),
      body: ListView(
        children: [
          for (final d in demos)
            ListTile(
              title: Text(d.title),
              subtitle: Text(d.description),
              trailing: const Icon(Icons.chevron_right),
              onTap: () =>
                  Navigator.of(context)
                      .push(MaterialPageRoute(builder: d.builder)),
            ),
        ],
      ),
    );
  }
}
