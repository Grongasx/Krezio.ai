import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../../../ai/voice/voice_conversation_controller.dart';
import '../../../../theme/krezio_theme.dart';



class VoiceConversationModal extends StatefulWidget {
  final VoiceConversationController controller;

  const VoiceConversationModal({
    Key? key,
    required this.controller,
  }) : super(key: key);

  static Future<void> show(BuildContext context, VoiceConversationController controller) {
    return showGeneralDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withOpacity(0.85),
      transitionDuration: const Duration(milliseconds: 350),
      pageBuilder: (context, anim1, anim2) {
        return VoiceConversationModal(controller: controller);
      },
      transitionBuilder: (context, anim1, anim2, child) {
        return FadeTransition(
          opacity: anim1,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.95, end: 1.0).animate(
              CurvedAnimation(parent: anim1, curve: Curves.easeOutCubic),
            ),
            child: child,
          ),
        );
      },
    );
  }

  @override
  State<VoiceConversationModal> createState() => _VoiceConversationModalState();
}

class _VoiceConversationModalState extends State<VoiceConversationModal> with TickerProviderStateMixin {
  late AnimationController _pulseController;
  late AnimationController _rotationController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);

    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat();

    widget.controller.initialize().then((_) {
      if (mounted) {
        widget.controller.startConversation(speakGreeting: true);
      }
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _rotationController.dispose();
    widget.controller.stopConversation();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080B11),
      body: SafeArea(
        child: Stack(
          children: [
            // Ambient background glow
            Positioned.fill(
              child: ValueListenableBuilder<VoiceState>(
                valueListenable: widget.controller.stateNotifier,
                builder: (context, state, _) {
                  Color glowColor = KrezioColors.aiPurple;
                  if (state == VoiceState.listening) glowColor = const Color(0xFF06B6D4);
                  if (state == VoiceState.speaking) glowColor = KrezioColors.emeraldGreen;
                  if (state == VoiceState.paused) glowColor = KrezioColors.friendlyOrange;

                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 600),
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: Alignment.center,
                        radius: 0.85,
                        colors: [
                          glowColor.withOpacity(0.12),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),

            Column(
              children: [
                _buildHeader(context),
                Expanded(
                  child: Center(
                    child: _buildNeuralVoiceOrb(),
                  ),
                ),
                _buildTranscriptionPanel(),
                const SizedBox(height: 20),
                _buildControlsBar(context),
                const SizedBox(height: 24),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [KrezioColors.aiPurple, Color(0xFF6366F1)],
                  ),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: KrezioColors.aiPurple.withOpacity(0.4),
                      blurRadius: 10,
                    ),
                  ],
                ),
                child: const Icon(Icons.record_voice_over, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'César • Modo Conversa',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.3,
                    ),
                  ),
                  Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: const BoxDecoration(
                          color: KrezioColors.emeraldGreen,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '100% ON-DEVICE • PRIVACIDADE TOTAL',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.6),
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          Row(
            children: [
              Tooltip(
                message: 'Modelo de Voz: Piper ONNX (pt_BR-faber-medium)\n100% On-Device Neural',
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => _showVoiceTuningSheet(context),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: KrezioColors.aiPurple.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: KrezioColors.aiPurple.withOpacity(0.5)),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.memory, color: Color(0xFFA78BFA), size: 14),
                        SizedBox(width: 6),
                        Text(
                          'ONNX Piper',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.white70, size: 26),
                tooltip: 'Encerrar conversa',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showVoiceTuningSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161A23),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final tts = widget.controller.voiceSynthesis;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: KrezioColors.aiPurple.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(Icons.memory, color: Color(0xFFA78BFA), size: 20),
                          ),
                          const SizedBox(width: 10),
                          const Text(
                            'Modelo Neural On-Device (ONNX)',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white54),
                        onPressed: () => Navigator.pop(sheetContext),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  // On-Device Neural ONNX Model Status Card
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          KrezioColors.aiPurple.withOpacity(0.25),
                          const Color(0xFF10B981).withOpacity(0.15),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: KrezioColors.aiPurple.withOpacity(0.4)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: KrezioColors.aiPurple.withOpacity(0.3),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.psychology, color: Color(0xFFA78BFA), size: 18),
                            ),
                            const SizedBox(width: 10),
                            const Expanded(
                              child: Text(
                                'Piper VITS • pt_BR-faber-medium',
                                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: KrezioColors.emeraldGreen.withOpacity(0.25),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: KrezioColors.emeraldGreen.withOpacity(0.5)),
                              ),
                              child: const Text(
                                'ONNX ATIVO',
                                style: TextStyle(color: KrezioColors.emeraldGreen, fontSize: 9, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Tamanho: 60.3 MB local • Taxa: 22.050 Hz\nPersona: Consultor financeiro maduro, acolhedor e seguro',
                          style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: 11, height: 1.4),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Cadência Neural / Velocidade', style: TextStyle(color: Colors.white70, fontSize: 13)),
                      Text(
                        '${(tts.speechRate).toStringAsFixed(2)}x',
                        style: const TextStyle(color: KrezioColors.emeraldGreen, fontWeight: FontWeight.bold, fontSize: 12),
                      ),
                    ],
                  ),
                  Slider(
                    value: tts.speechRate,
                    min: 0.70,
                    max: 1.30,
                    divisions: 12,
                    activeColor: KrezioColors.emeraldGreen,
                    inactiveColor: Colors.white12,
                    onChanged: (val) {
                      tts.setSpeechRate(val);
                      setSheetState(() {});
                    },
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: KrezioColors.aiPurple,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text(
                        'Ouvir Demonstração Neural do César (ONNX)',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      onPressed: () {
                        tts.speak('Olá! Sou o César, seu consultor financeiro no Krézio ai. Notou como minha voz neural soa natural agora?');
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }



  Widget _buildNeuralVoiceOrb() {
    return AnimatedBuilder(
      animation: Listenable.merge([_pulseController, _rotationController]),
      builder: (context, _) {
        return ValueListenableBuilder<VoiceState>(
          valueListenable: widget.controller.stateNotifier,
          builder: (context, state, _) {
            return ValueListenableBuilder<double>(
              valueListenable: widget.controller.audioLevelNotifier,
              builder: (context, audioLevel, _) {
                // Determine rich dynamic color palette & glows
                Color primaryGlow;
                Color secondaryGlow;
                Color accentCore;
                String statusLabel = 'Pronto para conversar';

                if (state == VoiceState.listening) {
                  primaryGlow = const Color(0xFF06B6D4); // Cyan Neon
                  secondaryGlow = const Color(0xFF3B82F6); // Electric Blue
                  accentCore = const Color(0xFF67E8F9);
                  statusLabel = 'Ouvindo você...';
                } else if (state == VoiceState.thinking) {
                  primaryGlow = KrezioColors.aiPurple; // Deep AI Purple
                  secondaryGlow = const Color(0xFFEC4899); // Hot Pink
                  accentCore = const Color(0xFFF472B6);
                  statusLabel = 'César raciocinando...';
                } else if (state == VoiceState.speaking) {
                  primaryGlow = KrezioColors.emeraldGreen; // Emerald Glow
                  secondaryGlow = const Color(0xFF059669);
                  accentCore = const Color(0xFF34D399);
                  statusLabel = 'César falando (ONNX Neural)...';
                } else if (state == VoiceState.paused) {
                  primaryGlow = KrezioColors.friendlyOrange;
                  secondaryGlow = Colors.amber;
                  accentCore = const Color(0xFFFDE047);
                  statusLabel = 'Conversa pausada';
                } else {
                  primaryGlow = KrezioColors.aiPurple;
                  secondaryGlow = const Color(0xFF6366F1);
                  accentCore = const Color(0xFFA78BFA);
                  statusLabel = 'César conectado • Modo ONNX';
                }

                final audioFactor = (audioLevel * 0.45);
                final pulseFactor = (_pulseController.value * 0.08);
                final dynamicScale = 1.0 + audioFactor + pulseFactor;
                final rot = _rotationController.value * 2 * math.pi;

                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GestureDetector(
                      onTap: () {
                        if (state == VoiceState.listening) {
                          if (widget.controller.userTranscriptNotifier.value.trim().isNotEmpty) {
                            widget.controller.manualCommitSpeech();
                          } else {
                            widget.controller.startListening();
                          }
                        } else if (state == VoiceState.speaking) {
                          widget.controller.voiceSynthesis.stop();
                          widget.controller.startListening();
                        } else {
                          widget.controller.startListening();
                        }
                      },
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: SizedBox(
                          width: 250,
                          height: 250,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              // 1. Broad Atmospheric Ambient Glow (Cinematic Bloom)
                              Container(
                                width: 170,
                                height: 170,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: primaryGlow.withValues(alpha: 0.40),
                                      blurRadius: 90,
                                      spreadRadius: 20 + (audioLevel * 25),
                                    ),
                                    BoxShadow(
                                      color: secondaryGlow.withValues(alpha: 0.30),
                                      blurRadius: 60,
                                      spreadRadius: 8,
                                    ),
                                    BoxShadow(
                                      color: accentCore.withValues(alpha: 0.20),
                                      blurRadius: 30,
                                      spreadRadius: 2,
                                    ),
                                  ],
                                ),
                              ),

                              // 2. Outer Audio-Reactive Breathing Ripple Ring
                              Transform.scale(
                                scale: dynamicScale * 1.35,
                                child: Container(
                                  width: 175,
                                  height: 175,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: primaryGlow.withValues(alpha: 0.16 + (audioLevel * 0.25)),
                                      width: 1.5,
                                    ),
                                  ),
                                ),
                              ),

                              // 3. Counter-Rotating Outer Holographic Gyroscope Ring
                              Transform.rotate(
                                angle: -rot * 0.7,
                                child: Container(
                                  width: 195,
                                  height: 195,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: secondaryGlow.withValues(alpha: 0.22),
                                      width: 1.2,
                                    ),
                                    gradient: SweepGradient(
                                      colors: [
                                        primaryGlow.withValues(alpha: 0.0),
                                        primaryGlow.withValues(alpha: 0.45),
                                        secondaryGlow.withValues(alpha: 0.0),
                                        accentCore.withValues(alpha: 0.65),
                                        primaryGlow.withValues(alpha: 0.0),
                                      ],
                                    ),
                                  ),
                                ),
                              ),

                              // 4. Primary Rotating Ethereal Aura Sweep Ring
                              Transform.rotate(
                                angle: rot,
                                child: Container(
                                  width: 170,
                                  height: 170,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: SweepGradient(
                                      colors: [
                                        primaryGlow.withValues(alpha: 0.75),
                                        secondaryGlow.withValues(alpha: 0.15),
                                        accentCore.withValues(alpha: 0.85),
                                        primaryGlow.withValues(alpha: 0.0),
                                      ],
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: primaryGlow.withValues(alpha: 0.45),
                                        blurRadius: 24,
                                      ),
                                    ],
                                  ),
                                ),
                              ),

                              // 5. The Glassmorphic 3D Neural Sphere Core
                              Transform.scale(
                                scale: dynamicScale,
                                child: Container(
                                  width: 140,
                                  height: 140,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: RadialGradient(
                                      center: const Alignment(-0.35, -0.4),
                                      radius: 0.95,
                                      colors: [
                                        Colors.white.withValues(alpha: 0.95),
                                        accentCore.withValues(alpha: 0.85),
                                        primaryGlow,
                                        secondaryGlow.withValues(alpha: 0.9),
                                        const Color(0xFF0B0F19),
                                      ],
                                      stops: const [0.0, 0.25, 0.55, 0.80, 1.0],
                                    ),
                                    border: Border.all(
                                      color: Colors.white.withValues(alpha: 0.50),
                                      width: 1.8,
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: primaryGlow.withValues(alpha: 0.65),
                                        blurRadius: 40,
                                        spreadRadius: 4,
                                      ),
                                      BoxShadow(
                                        color: Colors.black.withValues(alpha: 0.85),
                                        blurRadius: 25,
                                        offset: const Offset(0, 14),
                                      ),
                                    ],
                                  ),
                                  child: Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      // Specular 3D Glass Sheen Highlight (Top Half)
                                      Positioned(
                                        top: 5,
                                        left: 16,
                                        right: 16,
                                        height: 52,
                                        child: Container(
                                          decoration: BoxDecoration(
                                            borderRadius: const BorderRadius.vertical(
                                              top: Radius.circular(80),
                                              bottom: Radius.circular(40),
                                            ),
                                            gradient: LinearGradient(
                                              begin: Alignment.topCenter,
                                              end: Alignment.bottomCenter,
                                              colors: [
                                                Colors.white.withValues(alpha: 0.55),
                                                Colors.white.withValues(alpha: 0.0),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),

                                      // Central Dynamic Soundwave Equalizer (Replaces crude spinning icon!)
                                      _buildDynamicNeuralWaveCore(
                                        audioLevel: audioLevel,
                                        pulse: _pulseController.value,
                                        state: state,
                                        accentColor: accentCore,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Futuristic Glassmorphic State Indicator Capsule
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF141A26).withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(30),
                        border: Border.all(
                          color: primaryGlow.withValues(alpha: 0.45),
                          width: 1.2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: primaryGlow.withValues(alpha: 0.22),
                            blurRadius: 18,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Live Pulsing Dot
                          Container(
                            width: 9,
                            height: 9,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: primaryGlow,
                              boxShadow: [
                                BoxShadow(
                                  color: primaryGlow.withValues(alpha: 0.9),
                                  blurRadius: 8,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            statusLabel,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      state == VoiceState.listening
                          ? (widget.controller.userTranscriptNotifier.value.trim().isNotEmpty
                              ? '✨ Aguarde 1s em silêncio ou toque na esfera para enviar'
                              : 'Fale normalmente ou toque na esfera')
                          : (state == VoiceState.speaking ? 'Toque na esfera para interromper' : ''),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.45),
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  /// Harmonic soundwave frequency bars dancing inside the neural orb.
  Widget _buildDynamicNeuralWaveCore({
    required double audioLevel,
    required double pulse,
    required VoiceState state,
    required Color accentColor,
  }) {
    if (state == VoiceState.thinking) {
      return Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              Colors.white.withValues(alpha: 0.8),
              accentColor.withValues(alpha: 0.4),
              Colors.transparent,
            ],
          ),
        ),
        child: const Center(
          child: SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
            ),
          ),
        ),
      );
    }

    // 5 dynamic soundwave frequency bars reacting to audioLevel & breath pulse
    final bars = [
      0.35 + (audioLevel * 0.45) + (math.sin(pulse * math.pi) * 0.15),
      0.65 + (audioLevel * 0.70) + (math.cos(pulse * math.pi) * 0.20),
      0.90 + (audioLevel * 0.90) + (math.sin(pulse * math.pi * 1.5) * 0.15),
      0.60 + (audioLevel * 0.65) + (math.cos(pulse * math.pi * 1.2) * 0.20),
      0.30 + (audioLevel * 0.40) + (math.sin(pulse * math.pi * 0.8) * 0.15),
    ];

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: bars.map((heightFactor) {
        final clampedHeight = (heightFactor.clamp(0.25, 1.2) * 36.0);
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 2.5),
          width: 4.5,
          height: clampedHeight,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.white,
                accentColor,
                Colors.white.withValues(alpha: 0.85),
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: accentColor.withValues(alpha: 0.8),
                blurRadius: 8,
                spreadRadius: 1,
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildTranscriptionPanel() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(minHeight: 110, maxHeight: 160),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: const Color(0xFF141923).withOpacity(0.85),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Colors.white.withOpacity(0.08),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // User Transcript
              ValueListenableBuilder<String>(
                valueListenable: widget.controller.userTranscriptNotifier,
                builder: (context, userText, _) {
                  if (userText.isEmpty) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('🗣️ ', style: TextStyle(fontSize: 14)),
                            Expanded(
                              child: Text(
                                userText,
                                style: const TextStyle(
                                  color: Color(0xFFE2E8F0),
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  height: 1.35,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Align(
                          alignment: Alignment.centerRight,
                          child: InkWell(
                            onTap: () => widget.controller.manualCommitSpeech(),
                            borderRadius: BorderRadius.circular(14),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: const Color(0xFF06B6D4).withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: const Color(0xFF06B6D4).withValues(alpha: 0.6),
                                  width: 1,
                                ),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.send_rounded, color: Color(0xFF06B6D4), size: 12),
                                  SizedBox(width: 4),
                                  Text(
                                    'Enviar fala agora ➔',
                                    style: TextStyle(
                                      color: Color(0xFF67E8F9),
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),

              // César Speech
              ValueListenableBuilder<String>(
                valueListenable: widget.controller.cesarSpeechNotifier,
                builder: (context, cesarText, _) {
                  if (cesarText.isEmpty) {
                    return ValueListenableBuilder<VoiceState>(
                      valueListenable: widget.controller.stateNotifier,
                      builder: (context, state, _) {
                        return Text(
                          state == VoiceState.listening
                              ? 'Fale com o César (ex: "emprestei 100 pro João", "gastei 50 no mercado")...'
                              : 'Conectado ao César.',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.4),
                            fontSize: 13,
                            fontStyle: FontStyle.italic,
                          ),
                        );
                      },
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('🟣 ', style: TextStyle(fontSize: 14)),
                      Expanded(
                        child: Text(
                          cesarText,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildControlsBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Mute Mic Toggle
          ValueListenableBuilder<bool>(
            valueListenable: widget.controller.isMutedNotifier,
            builder: (context, isMuted, _) {
              return _buildCircleButton(
                icon: isMuted ? Icons.mic_off : Icons.mic,
                color: isMuted ? Colors.redAccent : Colors.white24,
                tooltip: isMuted ? 'Desmutar Microfone' : 'Mutar Microfone',
                onTap: () => widget.controller.toggleMute(),
              );
            },
          ),

          // Hands-free Toggle
          ValueListenableBuilder<bool>(
            valueListenable: widget.controller.isHandsFreeNotifier,
            builder: (context, isHandsFree, _) {
              return InkWell(
                borderRadius: BorderRadius.circular(24),
                onTap: () => widget.controller.toggleHandsFree(),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: isHandsFree ? KrezioColors.aiPurple.withOpacity(0.25) : Colors.white10,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: isHandsFree ? KrezioColors.aiPurple : Colors.white24,
                      width: 1.2,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isHandsFree ? Icons.sync : Icons.touch_app,
                        color: isHandsFree ? KrezioColors.aiPurple : Colors.white70,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        isHandsFree ? 'MÃOS LIVRES' : 'MANUAL',
                        style: TextStyle(
                          color: isHandsFree ? Colors.white : Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),

          // Mute Speaker Toggle
          ValueListenableBuilder<bool>(
            valueListenable: widget.controller.isSpeakerMutedNotifier,
            builder: (context, isSpeakerMuted, _) {
              return _buildCircleButton(
                icon: isSpeakerMuted ? Icons.volume_off : Icons.volume_up,
                color: isSpeakerMuted ? Colors.amber : Colors.white24,
                tooltip: isSpeakerMuted ? 'Ativar Voz do César' : 'Silenciar César',
                onTap: () => widget.controller.toggleSpeaker(),
              );
            },
          ),

          // End Call Button
          _buildCircleButton(
            icon: Icons.call_end,
            color: Colors.red,
            tooltip: 'Encerrar conversa',
            onTap: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildCircleButton({
    required IconData icon,
    required Color color,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(28),
        onTap: onTap,
        child: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withOpacity(0.25),
            border: Border.all(color: color.withOpacity(0.7), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: color.withOpacity(0.2),
                blurRadius: 8,
              ),
            ],
          ),
          child: Icon(icon, color: Colors.white, size: 24),
        ),
      ),
    );
  }
}
