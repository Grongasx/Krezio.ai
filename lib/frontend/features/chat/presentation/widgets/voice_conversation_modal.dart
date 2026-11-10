import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../../../ai/voice/voice_conversation_controller.dart';
import '../../../../../ai/voice/voice_synthesis_service.dart';
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

    // "tchau César" or 10 s of silence in hands-free close the conversation.
    widget.controller.onConversationEnded = () {
      if (mounted) Navigator.of(context).maybePop();
    };
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
                const SizedBox(height: KrezioSpace.xl),
                _buildControlsBar(context),
                const SizedBox(height: KrezioSpace.xxl),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _voiceLabel(VoiceAvailability availability) => switch (availability) {
        VoiceAvailability.checking => 'Verificando a voz',
        VoiceAvailability.systemVoice => 'Voz do sistema',
        VoiceAvailability.piper => 'Piper disponível',
        VoiceAvailability.unavailable => 'Voz indisponível',
      };

  Widget _buildHeader(BuildContext context) {
    final availability = widget.controller.voiceSynthesis.availabilityNotifier;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.lg, vertical: KrezioSpace.md),
      child: Row(
        children: [
          const Icon(Icons.record_voice_over_outlined, color: Color(0xFFA78BFA)),
          const SizedBox(width: KrezioSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Conversa com o César',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: KrezioFont.bodyLarge,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                ValueListenableBuilder<VoiceAvailability>(
                  valueListenable: availability,
                  builder: (context, state, _) {
                    final label = _voiceLabel(state);
                    return Semantics(
                      liveRegion: true,
                      child: Text(
                        state == VoiceAvailability.unavailable ? '$label. Continue pelo chat.' : label,
                        style: const TextStyle(color: Colors.white70, fontSize: KrezioFont.caption),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.tune, color: Colors.white70),
            tooltip: 'Configurar voz',
            onPressed: () => _showVoiceTuningSheet(context),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, color: Colors.white70),
            tooltip: 'Voltar ao chat',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  void _showVoiceTuningSheet(BuildContext context) {
    final tts = widget.controller.voiceSynthesis;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161A23),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(KrezioSpace.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Configurar voz',
                  style: TextStyle(color: Colors.white, fontSize: KrezioFont.title, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: KrezioSpace.sm),
                ValueListenableBuilder<VoiceAvailability>(
                  valueListenable: tts.availabilityNotifier,
                  builder: (context, state, _) => Text(
                    _voiceLabel(state),
                    style: const TextStyle(color: Colors.white70, fontSize: KrezioFont.bodySmall),
                  ),
                ),
                const SizedBox(height: KrezioSpace.lg),
                Text(
                  'Velocidade da fala: ${tts.speechRate.toStringAsFixed(2)}× (${VoiceSynthesisService.speedLabelOf(tts.speechRate)})',
                  style: const TextStyle(color: Colors.white70, fontSize: KrezioFont.bodySmall),
                ),
                Slider(
                  value: tts.speechRate.clamp(0.75, 2.0),
                  min: 0.75,
                  max: 2.0,
                  divisions: 25,
                  activeColor: KrezioColors.emeraldGreen,
                  inactiveColor: Colors.white12,
                  onChanged: (value) {
                    tts.setSpeechRate(value);
                    setSheetState(() {});
                  },
                ),
                Wrap(
                  spacing: KrezioSpace.xs,
                  runSpacing: KrezioSpace.xs,
                  children: [
                    for (final preset in VoiceSynthesisService.speedPresets)
                      ChoiceChip(
                        label: Text('${preset}×', style: const TextStyle(fontSize: KrezioFont.caption)),
                        selected: (tts.speechRate - preset).abs() < 0.03,
                        selectedColor: KrezioColors.emeraldGreen.withValues(alpha: 0.25),
                        onSelected: (_) {
                          tts.setSpeechRate(preset);
                          setSheetState(() {});
                        },
                      ),
                  ],
                ),
                const SizedBox(height: KrezioSpace.md),
                ValueListenableBuilder<bool>(
                  valueListenable: widget.controller.isSpeakerMutedNotifier,
                  builder: (context, muted, _) => ElevatedButton.icon(
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('Ouvir exemplo'),
                    onPressed: muted ? null : widget.controller.previewVoice,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
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
                  statusLabel = 'Ouvindo você... (diga "tchau César" para encerrar)';
                } else if (state == VoiceState.thinking) {
                  primaryGlow = KrezioColors.aiPurple; // Deep AI Purple
                  secondaryGlow = const Color(0xFFEC4899); // Hot Pink
                  accentCore = const Color(0xFFF472B6);
                  statusLabel = 'César raciocinando...';
                } else if (state == VoiceState.speaking) {
                  primaryGlow = KrezioColors.emeraldGreen; // Emerald Glow
                  secondaryGlow = const Color(0xFF059669);
                  accentCore = const Color(0xFF34D399);
                  statusLabel = 'César respondendo...';
                } else if (state == VoiceState.paused) {
                  primaryGlow = KrezioColors.friendlyOrange;
                  secondaryGlow = Colors.amber;
                  accentCore = const Color(0xFFFDE047);
                  statusLabel = 'Conversa pausada';
                } else {
                  primaryGlow = KrezioColors.aiPurple;
                  secondaryGlow = const Color(0xFF6366F1);
                  accentCore = const Color(0xFFA78BFA);
                  statusLabel = 'Pronto para conversar';
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
                          widget.controller.stopRecordingUserSpeech(processTranscript: true);
                        } else if (state == VoiceState.speaking) {
                          widget.controller.interruptCesarSpeech();
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
                    const SizedBox(height: KrezioSpace.xxl),

                    // Futuristic Glassmorphic State Indicator Capsule
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.lg, vertical: KrezioSpace.md),
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
                          const SizedBox(width: KrezioSpace.md),
                          Text(
                            statusLabel,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: KrezioFont.bodySmall,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: KrezioSpace.md),
                    _buildImmediateSpeechActionButtons(state),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  /// Explicit, one-tap buttons to stop recording user speech or stop César from speaking.
  Widget _buildImmediateSpeechActionButtons(VoiceState state) {
    if (state == VoiceState.listening) {
      return ValueListenableBuilder<String>(
        valueListenable: widget.controller.userTranscriptNotifier,
        builder: (context, transcript, _) {
          final hasWords = transcript.trim().isNotEmpty;
          return Wrap(
            alignment: WrapAlignment.center,
            spacing: KrezioSpace.sm,
            runSpacing: KrezioSpace.xs,
            children: [
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent.withValues(alpha: 0.90),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.lg, vertical: KrezioSpace.sm),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                ),
                icon: const Icon(Icons.stop_circle_rounded, size: 18),
                label: const Text(
                  'Parar de gravar',
                  style: TextStyle(fontSize: KrezioFont.small, fontWeight: FontWeight.bold),
                ),
                onPressed: () => widget.controller.stopRecordingUserSpeech(processTranscript: false),
              ),
              if (hasWords)
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF06B6D4),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.lg, vertical: KrezioSpace.sm),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                  ),
                  icon: const Icon(Icons.send_rounded, size: 16),
                  label: const Text(
                    'Concluir e enviar fala',
                    style: TextStyle(fontSize: KrezioFont.small, fontWeight: FontWeight.bold),
                  ),
                  onPressed: () => widget.controller.stopRecordingUserSpeech(processTranscript: true),
                ),
            ],
          );
        },
      );
    }

    if (state == VoiceState.speaking) {
      return ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.redAccent,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.xl, vertical: KrezioSpace.sm),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        ),
        icon: const Icon(Icons.stop_circle_rounded, size: 18),
        label: const Text(
          'Parar fala do César',
          style: TextStyle(fontSize: KrezioFont.small, fontWeight: FontWeight.bold),
        ),
        onPressed: () => widget.controller.interruptCesarSpeech(),
      );
    }

    if (state == VoiceState.paused || state == VoiceState.idle) {
      return ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: KrezioColors.aiPurple,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.xl, vertical: KrezioSpace.sm),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        ),
        icon: const Icon(Icons.mic_rounded, size: 18),
        label: const Text(
          'Gravar minha fala',
          style: TextStyle(fontSize: KrezioFont.small, fontWeight: FontWeight.bold),
        ),
        onPressed: () => widget.controller.startListening(),
      );
    }

    return const SizedBox.shrink();
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
          margin: const EdgeInsets.symmetric(horizontal: KrezioSpace.hair),
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
      padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.xxl),
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(minHeight: 110, maxHeight: 160),
        padding: const EdgeInsets.all(KrezioSpace.lg),
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
                    padding: const EdgeInsets.only(bottom: KrezioSpace.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('🗣️ ', style: TextStyle(fontSize: KrezioFont.body)),
                            Expanded(
                              child: Text(
                                userText,
                                style: const TextStyle(
                                  color: Color(0xFFE2E8F0),
                                  fontSize: KrezioFont.body,
                                  fontWeight: FontWeight.w500,
                                  height: 1.35,
                                ),
                              ),
                            ),
                          ],
                        ),
                        ValueListenableBuilder<VoiceState>(
                          valueListenable: widget.controller.stateNotifier,
                          builder: (context, currentState, _) {
                            if (currentState != VoiceState.listening) return const SizedBox.shrink();
                            return Padding(
                              padding: const EdgeInsets.only(top: KrezioSpace.sm),
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: InkWell(
                                  onTap: () => widget.controller.stopRecordingUserSpeech(processTranscript: true),
                                  borderRadius: BorderRadius.circular(14),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.md, vertical: KrezioSpace.xs),
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
                                        SizedBox(width: KrezioSpace.xs),
                                        Text(
                                          'Enviar fala agora ➔',
                                          style: TextStyle(
                                            color: Color(0xFF67E8F9),
                                            fontSize: KrezioFont.caption,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
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
                            fontSize: KrezioFont.bodySmall,
                            fontStyle: FontStyle.italic,
                          ),
                        );
                      },
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('🟣 ', style: TextStyle(fontSize: KrezioFont.body)),
                      Expanded(
                        child: Text(
                          cesarText,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: KrezioFont.body,
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
      padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.xxl),
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
                  padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.lg, vertical: KrezioSpace.md),
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
                      const SizedBox(width: KrezioSpace.sm),
                      Text(
                        isHandsFree ? 'MÃOS LIVRES' : 'MANUAL',
                        style: TextStyle(
                          color: isHandsFree ? Colors.white : Colors.white70,
                          fontSize: KrezioFont.small,
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
