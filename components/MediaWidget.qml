import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Services.Mpris

Item {
    id: root

    implicitWidth: mainRow.implicitWidth
    implicitHeight: mainRow.implicitHeight

    // ── Detección de Spotify / MPRIS (tomado de SpotifyWidget.qml) ───
    readonly property var _allPlayers: Mpris.players.values

    readonly property var spotifyPlayer: {
        // 1. Prioridad: buscar Spotify
        for (var i = 0; i < _allPlayers.length; i++) {
            var p = _allPlayers[i];
            if (p && p.identity && p.identity.toLowerCase().includes("spotify")) {
                return p;
            }
        }
        // 2. Si no hay Spotify, buscar reproductor que esté sonando
        for (var j = 0; j < _allPlayers.length; j++) {
            if (_allPlayers[j] && _allPlayers[j].playbackState === MprisPlaybackState.Playing) {
                return _allPlayers[j];
            }
        }
        // 3. Primer reproductor disponible
        return _allPlayers.length > 0 ? _allPlayers[0] : null;
    }

    readonly property bool hasSpotify: root.spotifyPlayer !== null
    readonly property bool isPlaying: root.hasSpotify && root.spotifyPlayer.playbackState === MprisPlaybackState.Playing
    readonly property string currentTitle: root.hasSpotify && root.spotifyPlayer.trackTitle ? root.spotifyPlayer.trackTitle : "Sin reproducción"
    readonly property string currentArtist: root.hasSpotify && (root.spotifyPlayer.trackArtist || root.spotifyPlayer.trackAlbum)
                                           ? (root.spotifyPlayer.trackArtist || root.spotifyPlayer.trackAlbum)
                                           : "Spotify"
    readonly property string artUrl: root.hasSpotify && root.spotifyPlayer.trackArtUrl ? root.spotifyPlayer.trackArtUrl : ""

    RowLayout {
        id: mainRow
        anchors.fill: parent
        spacing: 12

        // Carátula del álbum / CD
        Rectangle {
            id: coverContainer
            width: 80
            height: 80
            radius: 12
            color: "#181825"
            border.color: "#28283d"
            border.width: 1
            clip: true
            Layout.alignment: Qt.AlignVCenter

            // Portada real provista por Spotify / MPRIS
            Item {
                id: albumCover
                anchors.fill: parent
                visible: root.hasSpotify && root.spotifyPlayer.trackArtUrl !== ""

                Rectangle {
                    id: albumMask
                    anchors.fill: parent
                    radius: 12
                    color: "white"
                    visible: false
                    layer.enabled: true
                }

                Image {
                    id: image
                    anchors.fill: parent
                    source: root.hasSpotify ? root.spotifyPlayer.trackArtUrl : ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    smooth: true
                    visible: false
                    layer.enabled: true
                }

                MultiEffect {
                    anchors.fill: parent
                    source: image
                    maskEnabled: true
                    antialiasing: true
                    maskSource: albumMask
                }
            }

            // Fallback: Disco vinilo / CD con gradiente estilizado
            Rectangle {
                anchors.fill: parent
                radius: 12
                visible: !albumCover.visible
                gradient: Gradient {
                    GradientStop { position: 0.0; color: "#e5c890" }
                    GradientStop { position: 0.5; color: "#ea999c" }
                    GradientStop { position: 1.0; color: "#e78284" }
                }

                Rectangle {
                    width: 18
                    height: 18
                    radius: 9
                    color: "#11111b"
                    anchors.centerIn: parent
                    border.color: "#303446"
                    border.width: 2
                }
            }
        }

        // Información de la pista y controles
        ColumnLayout {
            Layout.alignment: Qt.AlignVCenter
            spacing: 2

            // Título de la pista
            Text {
                text: root.currentTitle
                color: "#ffffff"
                font.pixelSize: 14
                font.weight: Font.DemiBold
                font.family: "Noto Sans, Inter, system-ui, sans-serif"
                elide: Text.ElideRight
                Layout.maximumWidth: 155
            }

            // Artista / álbum
            Text {
                text: root.currentArtist
                color: "#a6adc8"
                font.pixelSize: 11
                font.family: "Noto Sans, Inter, system-ui, sans-serif"
                elide: Text.ElideRight
                Layout.maximumWidth: 155
            }

            Item {
                implicitHeight: 2
            }

            // ── Controles de reproducción interactivos ──
            RowLayout {
                spacing: 8

                // Botón Anterior
                Rectangle {
                    id: prevBtn
                    width: 24
                    height: 24
                    radius: 12
                    color: prevMouse.pressed ? "#313244" : (prevMouse.containsMouse ? "#232433" : "transparent")

                    Behavior on color { ColorAnimation { duration: 100 } }

                    Text {
                        anchors.centerIn: parent
                        text: "󰒮"
                        color: prevMouse.containsMouse ? "#ffffff" : "#a6adc8"
                        font.pixelSize: 12
                    }

                    MouseArea {
                        id: prevMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (root.hasSpotify) {
                                root.spotifyPlayer.previous();
                            }
                        }
                    }
                }

                // Botón Play / Pausa
                Rectangle {
                    id: playBtn
                    width: 28
                    height: 28
                    radius: 14
                    color: playMouse.pressed ? "#45475a" : (playMouse.containsMouse ? "#313244" : "#1e2030")
                    border.color: playMouse.containsMouse ? "#585b70" : "#313244"
                    border.width: 1

                    Behavior on color { ColorAnimation { duration: 100 } }

                    Text {
                        anchors.centerIn: parent
                        text: root.isPlaying ? "󰏤" : "󰐊"
                        color: "#ffffff"
                        font.pixelSize: 12
                    }

                    MouseArea {
                        id: playMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (!root.hasSpotify) return;
                            if (root.isPlaying) {
                                root.spotifyPlayer.pause();
                            } else {
                                root.spotifyPlayer.play();
                            }
                        }
                    }
                }

                // Botón Siguiente
                Rectangle {
                    id: nextBtn
                    width: 24
                    height: 24
                    radius: 12
                    color: nextMouse.pressed ? "#313244" : (nextMouse.containsMouse ? "#232433" : "transparent")

                    Behavior on color { ColorAnimation { duration: 100 } }

                    Text {
                        anchors.centerIn: parent
                        text: "󰒭"
                        color: nextMouse.containsMouse ? "#ffffff" : "#a6adc8"
                        font.pixelSize: 12
                    }

                    MouseArea {
                        id: nextMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (root.hasSpotify) {
                                root.spotifyPlayer.next();
                            }
                        }
                    }
                }
            }
        }
    }
}
