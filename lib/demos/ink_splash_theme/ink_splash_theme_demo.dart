import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

/// Demo: dark <-> light theme switch where the new theme spills out of the
/// toggle button like liquid spreading across the screen.
///
/// How it works:
///  1. Take a screenshot of the screen in its current theme.
///  2. Switch the theme underneath.
///  3. Run a small spill simulation ([_LiquidSim]) and erase the screenshot
///     wherever the liquid has reached, so the new theme "is" the liquid.
///     The edge is drawn through a blur + alpha-threshold ("metaball") filter
///     so it stays round and wobbly and merges with blobs like real liquid.
class InkSplashThemeDemo extends StatefulWidget {
  const InkSplashThemeDemo({super.key});

  @override
  State<InkSplashThemeDemo> createState() => _InkSplashThemeDemoState();
}

class _InkSplashThemeDemoState extends State<InkSplashThemeDemo>
    with SingleTickerProviderStateMixin {
  final _boundaryKey = GlobalKey();
  final _toggleKey = GlobalKey();

  late final Ticker _ticker = createTicker(_onTick);
  Duration _lastTick = Duration.zero;

  bool _isDark = false;
  ui.Image? _snapshot;
  _LiquidSim? _sim;

  @override
  void dispose() {
    _ticker.dispose();
    _sim?.dispose();
    _snapshot?.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_sim != null) return;

    final boundary =
        _boundaryKey.currentContext!.findRenderObject()
            as RenderRepaintBoundary;
    final toggleBox =
        _toggleKey.currentContext!.findRenderObject() as RenderBox;
    final toggleCenter = boundary.globalToLocal(
      toggleBox.localToGlobal(toggleBox.size.center(Offset.zero)),
    );

    // In debug mode toImage() asserts the boundary isn't waiting to be painted
    // (the button's tap ripple makes it dirty). Wait for a painted frame.
    for (var i = 0; i < 10 && boundary.debugNeedsPaint; i++) {
      await WidgetsBinding.instance.endOfFrame;
    }
    if (!mounted) return;

    final image = await boundary.toImage(
      pixelRatio: View.of(context).devicePixelRatio,
    );
    if (!mounted) return;

    setState(() {
      _snapshot = image;
      _sim = _LiquidSim(size: boundary.size, source: toggleCenter);
      _isDark = !_isDark;
    });
    _lastTick = Duration.zero;
    _ticker.start();
  }

  void _onTick(Duration elapsed) {
    final sim = _sim;
    if (sim == null) return;
    // Clamp dt so a dropped frame doesn't make the liquid teleport.
    final dt = ((elapsed - _lastTick).inMicroseconds / 1e6).clamp(0.0, 1 / 30);
    _lastTick = elapsed;
    sim.step(dt);
    if (sim.done) {
      _ticker.stop();
      setState(() {
        _sim = null;
        _snapshot?.dispose();
        _snapshot = null;
      });
      sim.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.deepPurple,
        brightness: _isDark ? Brightness.dark : Brightness.light,
      ),
    );

    return Theme(
      data: theme,
      child: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            key: _boundaryKey,
            child: Scaffold(
              appBar: AppBar(
                title: const Text('Ink Splash Theme'),
                actions: [
                  IconButton(
                    key: _toggleKey,
                    tooltip: 'Toggle theme',
                    icon: Icon(_isDark ? Icons.light_mode : Icons.dark_mode),
                    onPressed: _toggle,
                  ),
                ],
              ),
              body: const _SampleContent(),
            ),
          ),
          if (_snapshot != null && _sim != null)
            IgnorePointer(
              child: CustomPaint(
                painter: _LiquidPainter(image: _snapshot!, sim: _sim!),
              ),
            ),
        ],
      ),
    );
  }
}

/// A small blob of liquid that has run out ahead of the main front.
class _Blob {
  _Blob(this.pos, this.r);
  final Offset pos;
  double r;
}

/// Liquid spilling across a flat surface, seen from above.
///
/// The edge of the spill is a polar curve around the button: one radius per
/// angle. Every frame each radius advances at its own speed:
///  - a moving pattern of "surges" makes some parts race ahead as fingers
///    while others hold back, and the pattern keeps shifting over time;
///  - surface tension (smoothing between neighbours) rounds the fingers into
///    lobes and pulls lagging parts forward;
///  - small blobs run out ahead of the fastest fingers and get swallowed when
///    the front reaches them.
class _LiquidSim extends ChangeNotifier {
  _LiquidSim({required this.size, required this.source}) {
    for (var i = 0; i < _n; i++) {
      _rayLen[i] = _distanceToEdge(i * _da);
    }
    for (var k = 3; k <= 14; k++) {
      _surges.add((
        freq: k,
        amp:
            (k < 7 ? 0.5 : 0.22) * (0.5 + _rnd.nextDouble()) / math.sqrt(k / 3),
        phase: _rnd.nextDouble() * math.pi * 2,
        drift: (_rnd.nextDouble() - 0.5) * 3, // how fast the pattern shifts
      ));
    }
  }

  static const _n = 180; // edge resolution
  static const _da = math.pi * 2 / _n;
  static const _speed = 400.0; // average spreading speed, px/s
  static const _tension = 0.35; // surface-tension smoothing strength

  final Size size;
  final Offset source;
  final _rnd = math.Random();
  final radius = Float64List(_n);
  final _rayLen = Float64List(_n);
  final _surges = <({int freq, double amp, double phase, double drift})>[];
  final blobs = <_Blob>[];

  double _elapsed = 0;
  double _blobTimer = 0;
  bool done = false;

  double angleOf(int i) => i * _da;

  /// How far the screen extends from the button in direction [a].
  double _distanceToEdge(double a) {
    final dx = math.cos(a), dy = math.sin(a);
    var t = double.infinity;
    if (dx > 1e-9) t = math.min(t, (size.width - source.dx) / dx);
    if (dx < -1e-9) t = math.min(t, -source.dx / dx);
    if (dy > 1e-9) t = math.min(t, (size.height - source.dy) / dy);
    if (dy < -1e-9) t = math.min(t, -source.dy / dy);
    return t;
  }

  double _surge(double a) {
    var v = 0.0;
    for (final s in _surges) {
      v += s.amp * math.sin(s.freq * a + s.phase + s.drift * _elapsed);
    }
    return v;
  }

  void step(double dt) {
    _elapsed += dt;
    // A quick gush at first, then a steady push; after 3s hurry up so it
    // always finishes.
    final gush = 1 + 1.2 * math.exp(-_elapsed * 3);
    final hurry = _elapsed > 3 ? 1 + (_elapsed - 3) * 3 : 1.0;

    var best = 0, bestSurge = -1e9;
    var complete = true;
    for (var i = 0; i < _n; i++) {
      final cap = _rayLen[i] + 70;
      if (radius[i] >= cap) continue;
      complete = false;
      final m = _surge(i * _da);
      if (m > bestSurge && radius[i] < _rayLen[i]) {
        bestSurge = m;
        best = i;
      }
      final v = _speed * gush * hurry * math.max(0.12, 1 + m);
      radius[i] = math.min(cap, radius[i] + v * dt);
    }

    // Surface tension: pull each point toward its neighbours (a few passes).
    for (var pass = 0; pass < 2; pass++) {
      final prev = Float64List.fromList(radius);
      for (var i = 0; i < _n; i++) {
        final l = prev[(i - 1 + _n) % _n], r = prev[(i + 1) % _n];
        final avg = (l + r) / 2;
        // Only pull forward-lagging points up and round off sharp tips;
        // never shrink much, liquid doesn't retreat.
        radius[i] = math.max(prev[i] - 2, prev[i] + (avg - prev[i]) * _tension);
      }
    }

    // Blobs run out ahead of the fastest finger now and then.
    _blobTimer -= dt;
    if (_blobTimer <= 0 && radius[best] > 30 && radius[best] < _rayLen[best]) {
      _blobTimer = 0.04 + _rnd.nextDouble() * 0.08;
      final a = best * _da + (_rnd.nextDouble() - 0.5) * 0.25;
      final ahead = radius[best] + 18 + _rnd.nextDouble() * 40;
      blobs.add(
        _Blob(
          source + Offset.fromDirection(a, ahead),
          5 + _rnd.nextDouble() * 9,
        ),
      );
    }
    for (final b in blobs) {
      b.r += dt * 18; // they spread a little on their own
    }
    blobs.removeWhere((b) => _swallowed(b));

    done = complete || _elapsed > 7;
    notifyListeners();
  }

  bool _swallowed(_Blob b) {
    final d = b.pos - source;
    var a = d.direction;
    if (a < 0) a += math.pi * 2;
    final i = (a / _da).round() % _n;
    return radius[i] > d.distance + b.r;
  }
}

/// Draws the old-theme screenshot with the spilled liquid erased out of it.
class _LiquidPainter extends CustomPainter {
  _LiquidPainter({required this.image, required this.sim})
    : super(repaint: sim);

  final ui.Image image;
  final _LiquidSim sim;

  // Metaball trick: blur, then keep only pixels with alpha over ~45% with a
  // sharp edge. Edges get round like surface tension, and blobs near the
  // front reach out and merge with it like real liquid.
  static final _gooey = ui.ImageFilter.compose(
    outer: const ColorFilter.matrix([
      1, 0, 0, 0, 0, //
      0, 1, 0, 0, 0,
      0, 0, 1, 0, 0,
      0, 0, 0, 22, -22 * 0.45 * 255,
    ]),
    inner: ui.ImageFilter.blur(sigmaX: 7, sigmaY: 7),
  );

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final front = _frontPath(0);

    canvas.saveLayer(rect, Paint());
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      rect,
      Paint()..filterQuality = FilterQuality.medium,
    );

    // Soft shadow just outside the liquid: it looks thick and wet.
    canvas.saveLayer(
      rect.inflate(60),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.28)
        ..imageFilter = ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
    );
    final ink = Paint()..color = Colors.black;
    canvas.drawPath(_frontPath(4), ink);
    for (final b in sim.blobs) {
      canvas.drawCircle(b.pos, b.r + 3, ink);
    }
    canvas.restore();

    // Erase the liquid area -> the new theme shows through.
    canvas.saveLayer(
      rect.inflate(60),
      Paint()
        ..blendMode = BlendMode.dstOut
        ..imageFilter = _gooey,
    );
    canvas.drawPath(front, ink);
    for (final b in sim.blobs) {
      canvas.drawCircle(b.pos, b.r * 1.2, ink);
    }
    canvas.restore();
    canvas.restore();

    // Wet sheen: a faint highlight running just inside the edge.
    canvas.drawPath(
      _frontPath(-7),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Colors.white.withValues(alpha: 0.16)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5),
    );
  }

  /// The spill outline, pushed out by [grow] px (negative = inside).
  Path _frontPath(double grow) {
    final path = Path();
    for (var i = 0; i < _LiquidSim._n; i++) {
      final r = math.max(0.0, sim.radius[i] + grow);
      final p = sim.source + Offset.fromDirection(sim.angleOf(i), r);
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    return path..close();
  }

  @override
  bool shouldRepaint(_LiquidPainter old) =>
      old.image != image || old.sim != sim;
}

class _SampleContent extends StatelessWidget {
  const _SampleContent();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Tap the icon in the top right',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        const Text('Watch the new theme spread out like ink.'),
        const SizedBox(height: 24),
        for (final c in [
          scheme.primary,
          scheme.secondary,
          scheme.tertiary,
          scheme.surfaceContainerHighest,
        ])
          Container(
            height: 80,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: c,
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.palette),
            title: const Text('A card'),
            subtitle: const Text('Cards change colour with the theme too'),
            trailing: FilledButton(onPressed: () {}, child: const Text('Go')),
          ),
        ),
      ],
    );
  }
}
