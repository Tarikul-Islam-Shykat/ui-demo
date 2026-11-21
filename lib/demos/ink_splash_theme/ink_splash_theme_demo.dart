import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

/// Demo: dark <-> light theme switch where the new theme pours out of the
/// toggle button as liquid paint.
///
/// How it works:
///  1. Take a screenshot of the screen in its current theme.
///  2. Switch the theme underneath.
///  3. Run a small liquid simulation ([_LiquidSim]) and use the liquid as a
///     mask that erases the old screenshot, so the new theme "is" the paint:
///       - a burst of paint splashes out of the button, then a stream pours
///       - gravity pulls the drops down; they bounce off the screen edges
///       - drops land in a pool that fills the screen from the bottom up
///       - every impact makes the pool surface ripple and slosh, and fast
///         drops throw up splash droplets
///     Drops are drawn through a blur + alpha-threshold ("metaball") filter,
///     so nearby drops merge and pinch apart like real liquid.
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

/// One blob of paint flying through the air.
class _Drop {
  _Drop(this.pos, this.vel, this.r, {this.splash = false});
  Offset pos;
  Offset vel;
  final double r;

  /// Splash droplets are thrown up out of the pool, so they carry no new
  /// volume when they fall back in.
  final bool splash;
}

/// A tiny, cheap liquid simulation (pixels and seconds):
///  - drops: point particles with gravity, air drag and wall bounces
///  - pool: a rising level plus a 1D wave height-field for the surface
class _LiquidSim extends ChangeNotifier {
  _LiquidSim({required this.size, required this.source}) {
    // Initial burst: paint splashes out of the button in all directions.
    for (var i = 0; i < 30; i++) {
      final a = _rnd.nextDouble() * math.pi * 2;
      final speed = 150 + _rnd.nextDouble() * 550;
      drops.add(
        _Drop(
          source,
          Offset.fromDirection(a, speed) + const Offset(0, -100),
          6 + _rnd.nextDouble() * 9,
        ),
      );
    }
  }

  static const _cols = 80; // surface resolution
  static const _gravity = 2600.0;
  static const _emitRate = 150.0; // stream drops per second
  static const _fillSeconds = 2.6; // ~time for the pool to fill the screen
  static const _waveSpeed = 340.0;
  static const _maxDrops = 320;

  final Size size;
  final Offset source;
  final _rnd = math.Random();
  final drops = <_Drop>[];
  final _h = Float64List(_cols); // surface displacement (up = positive)
  final _v = Float64List(_cols); // surface vertical velocity

  /// Height of the calm pool surface above the bottom of the screen.
  double level = 0;
  double _elapsed = 0;
  double _emitAcc = 0;
  bool done = false;

  double get _dx => size.width / (_cols - 1);

  /// Total pool height needed (with margin so waves don't peek through).
  double get _fullLevel => size.height + 90;

  /// Level gained per absorbed stream drop of radius 9.
  double get _volumePerDrop => _fullLevel / (_emitRate * _fillSeconds);

  double columnY(int i) => size.height - level - _h[i];

  double surfaceY(double x) {
    final f = (x / _dx).clamp(0.0, _cols - 1.0);
    final i = f.floor().clamp(0, _cols - 2);
    final t = f - i;
    return size.height - level - (_h[i] * (1 - t) + _h[i + 1] * t);
  }

  bool get _sourceCovered => surfaceY(source.dx) < source.dy - 14;

  void step(double dt) {
    _elapsed += dt;

    // The stream keeps pouring until the pool rises over the button; after
    // that the paint keeps welling up at the same pace.
    if (!_sourceCovered) {
      _emitAcc += dt * _emitRate;
      while (_emitAcc >= 1 && drops.length < _maxDrops) {
        _emitAcc -= 1;
        drops.add(
          _Drop(
            source + Offset((_rnd.nextDouble() - 0.5) * 8, 8),
            Offset(
              -40 + (_rnd.nextDouble() - 0.5) * 50,
              60 + _rnd.nextDouble() * 80,
            ),
            7.5 + _rnd.nextDouble() * 3,
          ),
        );
      }
    } else {
      level += dt * _fullLevel / _fillSeconds;
    }

    // Fixed sub-steps keep the wave equation stable.
    const sub = 1 / 240;
    var rest = dt;
    while (rest > 1e-6) {
      final s = math.min(sub, rest);
      _substep(s);
      rest -= s;
    }

    var top = double.infinity;
    for (var i = 0; i < _cols; i++) {
      top = math.min(top, columnY(i));
    }
    done = (top < -25 && drops.isEmpty) || _elapsed > 9;
    notifyListeners();
  }

  void _substep(double dt) {
    // --- Pool surface: damped wave equation with a weak pull back to flat.
    final tension = _waveSpeed * _waveSpeed / (_dx * _dx);
    for (var i = 0; i < _cols; i++) {
      final l = _h[math.max(i - 1, 0)];
      final r = _h[math.min(i + 1, _cols - 1)];
      final acc = tension * (l + r - 2 * _h[i]) - 12 * _h[i] - 2.4 * _v[i];
      _v[i] += acc * dt;
    }
    for (var i = 0; i < _cols; i++) {
      _h[i] = (_h[i] + _v[i] * dt).clamp(-90.0, 90.0);
    }

    // --- Drops: gravity, air drag, walls, landing in the pool.
    final drag = 1 - 0.5 * dt;
    for (var k = drops.length - 1; k >= 0; k--) {
      final d = drops[k];
      d.vel = Offset(d.vel.dx * drag, (d.vel.dy + _gravity * dt) * drag);
      d.pos += d.vel * dt;

      final w = size.width;
      if (d.pos.dx < d.r && d.vel.dx < 0) {
        d.pos = Offset(d.r, d.pos.dy);
        d.vel = Offset(-d.vel.dx * 0.3, d.vel.dy * 0.8); // wet wall: sticky
      } else if (d.pos.dx > w - d.r && d.vel.dx > 0) {
        d.pos = Offset(w - d.r, d.pos.dy);
        d.vel = Offset(-d.vel.dx * 0.3, d.vel.dy * 0.8);
      }
      if (d.pos.dy < d.r && d.vel.dy < 0) {
        d.pos = Offset(d.pos.dx, d.r);
        d.vel = Offset(d.vel.dx * 0.8, -d.vel.dy * 0.2);
      }

      if (d.pos.dy + d.r * 0.3 >= surfaceY(d.pos.dx)) {
        drops.removeAt(k);
        _land(d);
      }
    }
  }

  void _land(_Drop d) {
    final mass = (d.r * d.r) / 81; // relative to a radius-9 drop
    if (!d.splash) level += _volumePerDrop * mass;

    // Push the surface down where it hit -> ripples travel outward.
    final c = (d.pos.dx / _dx).round();
    final impulse = d.vel.dy * 0.1 * mass;
    for (var k = -3; k <= 3; k++) {
      final i = c + k;
      if (i < 0 || i >= _cols) continue;
      _v[i] -= impulse * math.exp(-k * k / 3);
    }

    // Fast drops throw up a crown of splash droplets.
    if (d.vel.dy > 1100 && d.r > 5.5 && drops.length < _maxDrops) {
      final n = 1 + _rnd.nextInt(3);
      for (var j = 0; j < n; j++) {
        final r = math.max(4.5, d.r * (0.4 + _rnd.nextDouble() * 0.3));
        drops.add(
          _Drop(
            Offset(d.pos.dx, surfaceY(d.pos.dx) - r - 2),
            Offset(
              (_rnd.nextDouble() - 0.5) * 420 + d.vel.dx * 0.3,
              -(0.15 + _rnd.nextDouble() * 0.22) * d.vel.dy,
            ),
            r,
            splash: true,
          ),
        );
      }
    }
  }
}

/// Draws the old-theme screenshot with the liquid erased out of it.
class _LiquidPainter extends CustomPainter {
  _LiquidPainter({required this.image, required this.sim})
    : super(repaint: sim);

  final ui.Image image;
  final _LiquidSim sim;

  // Metaball trick: blur the drops, then keep only pixels whose alpha is over
  // ~40% with a sharp edge. Close drops merge, separating drops "neck" apart.
  static final _gooey = ui.ImageFilter.compose(
    outer: const ColorFilter.matrix([
      1, 0, 0, 0, 0, //
      0, 1, 0, 0, 0,
      0, 0, 1, 0, 0,
      0, 0, 0, 22, -22 * 0.4 * 255,
    ]),
    inner: ui.ImageFilter.blur(sigmaX: 4.5, sigmaY: 4.5),
  );

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    canvas.saveLayer(rect, Paint());
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      rect,
      Paint()..filterQuality = FilterQuality.medium,
    );

    // Everything drawn in this layer erases the screenshot (dstOut).
    canvas.saveLayer(
      rect.inflate(60),
      Paint()
        ..blendMode = BlendMode.dstOut
        ..imageFilter = _gooey,
    );
    final ink = Paint()..color = Colors.black;
    canvas.drawPath(_surfacePath(size, closed: true), ink);
    for (final d in sim.drops) {
      // Slightly oversized: the threshold filter shrinks blobs a little.
      canvas.drawCircle(d.pos, d.r * 1.15, ink);
    }
    canvas.restore();
    canvas.restore();

    // Glossy highlight just under the pool surface sells the "wet" look.
    if (sim.level > 0) {
      canvas.save();
      canvas.clipRect(rect);
      canvas.translate(0, 5);
      canvas.drawPath(
        _surfacePath(size, closed: false),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round
          ..color = Colors.white.withValues(alpha: 0.22),
      );
      canvas.restore();
    }
  }

  Path _surfacePath(Size size, {required bool closed}) {
    final path = Path();
    const pad = 60.0;
    if (closed) {
      path
        ..moveTo(-pad, size.height + pad)
        ..lineTo(-pad, sim.columnY(0));
    } else {
      path.moveTo(0, sim.columnY(0));
    }
    for (var i = 0; i < _LiquidSim._cols; i++) {
      path.lineTo(i * sim._dx, sim.columnY(i));
    }
    if (closed) {
      path
        ..lineTo(size.width + pad, sim.columnY(_LiquidSim._cols - 1))
        ..lineTo(size.width + pad, size.height + pad)
        ..close();
    }
    return path;
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
