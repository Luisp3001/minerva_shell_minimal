import QtQuick
import Quickshell

// ── Minerva_waveform — GPU ShaderEffect con análisis de audio en tiempo real ──────
// Reemplaza el anterior Canvas (CPU/JS) con un fragment shader que ejecuta
// Simplex Noise, 4 ondas de color con screen blend y glow gaussiano,
// todo modulado por RMS + 4 bandas FFT del audio de Minerva.

Item {
    id: root

    implicitWidth: 172
    implicitHeight: 38

    property bool isRecording: false
    property bool isTranscribing: false
    property bool isThinking: false
    property bool isSpeaking: false
    
    property bool isPendingTask: false
    property bool isUrgentTask: false
    property string taskUrgency: "" // "", "low", "medium", "urgent"

    // ── Datos de audio en tiempo real (alimentados por el backend) ─────
    property real audioRms:   0.0
    property real audioBand0: 0.0   // sub-bass  (20–80 Hz)
    property real audioBand1: 0.0   // bass      (80–300 Hz)
    property real audioBand2: 0.0   // mids      (300–2000 Hz)
    property real audioBand3: 0.0   // highs     (2000–8000 Hz)

    // ── Animated state properties ─────────────────────────────────────
    property real stateAmplitude: 0.10
    property real stateSpeed: 0.65
    property real stateOpacity: 0.55
    property real tintR: 0.0
    property real tintG: 0.0
    property real tintB: 0.0
    property real tintAmount: 0.0

    states: [
        State {
            name: "recording"
            when: root.isRecording
            PropertyChanges { target: root; stateAmplitude: 0.50; stateSpeed: 1.6; stateOpacity: 1.0; tintAmount: 0.0 }
        },
        State {
            name: "transcribing"
            when: root.isTranscribing && !root.isRecording
            PropertyChanges { target: root; stateAmplitude: 0.20; stateSpeed: 0.85; stateOpacity: 0.80; tintAmount: 0.0 }
        },
        State {
            name: "thinking"
            when: root.isThinking && !root.isRecording && !root.isTranscribing
            PropertyChanges { target: root; stateAmplitude: 0.28; stateSpeed: 3.4; stateOpacity: 0.90; tintAmount: 0.0 }
        },
        State {
            name: "speaking"
            when: root.isSpeaking
            PropertyChanges { target: root; stateAmplitude: 0.45; stateSpeed: 2.1; stateOpacity: 1.0; tintAmount: 0.0 }
        },
        State {
            name: "urgent_task"
            when: root.isUrgentTask || root.taskUrgency === "urgent"
            PropertyChanges {
                target: root
                stateAmplitude: 0.38
                stateSpeed: 2.6
                stateOpacity: 1.0
                tintR: 1.00; tintG: 0.15; tintB: 0.20; tintAmount: 0.85
            }
        },
        State {
            name: "pending_task_medium"
            when: root.taskUrgency === "medium"
            PropertyChanges {
                target: root
                stateAmplitude: 0.24
                stateSpeed: 1.4
                stateOpacity: 0.85
                tintR: 1.00; tintG: 0.72; tintB: 0.05; tintAmount: 0.80
            }
        },
        State {
            name: "pending_task"
            when: root.isPendingTask || root.taskUrgency === "low"
            PropertyChanges {
                target: root
                stateAmplitude: 0.20
                stateSpeed: 1
                stateOpacity: 0.80
                tintR: 0.10; tintG: 0.85; tintB: 0.45; tintAmount: 0.75
            }
        },
        State {
            name: "idle"
            when: !root.isRecording && !root.isThinking && !root.isSpeaking && !root.isTranscribing && !root.isPendingTask && !root.isUrgentTask && root.taskUrgency === ""
            PropertyChanges { target: root; stateAmplitude: 0.10; stateSpeed: 0.65; stateOpacity: 0.55; tintAmount: 0.0 }
        }
    ]

    Behavior on stateAmplitude { NumberAnimation { duration: 550; easing.type: Easing.InOutQuad } }
    Behavior on stateSpeed     { NumberAnimation { duration: 600; easing.type: Easing.InOutQuad } }
    Behavior on stateOpacity   { NumberAnimation { duration: 450; easing.type: Easing.InOutQuad } }
    Behavior on tintR          { NumberAnimation { duration: 500; easing.type: Easing.InOutQuad } }
    Behavior on tintG          { NumberAnimation { duration: 500; easing.type: Easing.InOutQuad } }
    Behavior on tintB          { NumberAnimation { duration: 500; easing.type: Easing.InOutQuad } }
    Behavior on tintAmount     { NumberAnimation { duration: 500; easing.type: Easing.InOutQuad } }

    // ── Continuous Phase Accumulator (avoids animation jumps) ──────────
    property real _t: 0

    Timer {
        interval: 16        // ~60 fps
        running: true
        repeat: true
        onTriggered: {
            root._t += 0.0335 * root.stateSpeed
        }
    }

    // ── GPU ShaderEffect ──────────────────────────────────────────────
    ShaderEffect {
        id: waveformShader
        anchors.fill: parent
        opacity: root.stateOpacity
        Behavior on opacity { NumberAnimation { duration: 450 } }

        // ── Uniforms → fragment shader ────────────────────────────────
        // El orden DEBE coincidir exactamente con el layout del uniform block en .frag
        property real u_time:       root._t
        property real u_rms:        root.audioRms
        property real u_band0:      root.audioBand0
        property real u_band1:      root.audioBand1
        property real u_band2:      root.audioBand2
        property real u_band3:      root.audioBand3
        property real u_amplitude:  root.stateAmplitude
        property real u_speed:      root.stateSpeed
        property real u_width:      width
        property real u_height:     height
        property real u_tintR:      root.tintR
        property real u_tintG:      root.tintG
        property real u_tintB:      root.tintB
        property real u_tintAmount: root.tintAmount

        fragmentShader: "shaders/waveform.frag.qsb"
    }
}
