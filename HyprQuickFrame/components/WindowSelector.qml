/*
 * This file contains code based on "HyprQuickshot"
 * Original Author: JamDon2 (Copyright 2025)
 * Licensed under the MIT License.
 *
 * Modifications and other code: Copyright (c) 2026 Ronin-CK
 *
 * Copyright (c) 2025 JamDon2
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */
 
import QtQuick  
import Quickshell.Hyprland

Item {  
    id: root

    property var monitor: Hyprland.focusedMonitor

    // Use global toplevels filtered by the active workspace instead of
    // workspace.toplevels, which can be incomplete or stale.
    property var windows: {
        let result = [];
        if (!root.monitor || !root.monitor.activeWorkspace) return result;
        let ws = root.monitor.activeWorkspace;
        let all = Hyprland.toplevels.values;
        for (let i = 0; i < all.length; i++) {
            if (all[i].workspace === ws)
                result.push(all[i]);
        }
        return result;
    }

    signal regionSelected(real x, real y, real width, real height)  
    property alias pressed: mouseArea.pressed

    property real mouseX: 0
    property real mouseY: 0
    onMouseXChanged: _doHoverCheck()
    onMouseYChanged: _doHoverCheck()
      
    property real dimOpacity: 0.6  
    property real borderRadius: 10.0  
    property real outlineThickness: 2.0  
    property url fragmentShader: Qt.resolvedUrl("../shaders/dimming.frag.qsb")  
      
    property point startPos  
    property real selectionX: 0  
    property real selectionY: 0  
    property real selectionWidth: 0  
    property real selectionHeight: 0  
      
    property bool animateSelection: true

    // Refresh toplevel IPC data on load so positions/sizes are current
    Component.onCompleted: {
        Hyprland.refreshToplevels();
    }

    // Centralized hover check: iterates all windows in one pass and
    // resets the selection when the cursor is outside every window.
    function _doHoverCheck() {
        if (!root.monitor || !root.monitor.lastIpcObject)
            return;

        const mx = root.mouseX;
        const my = root.mouseY;
        const monitorX = root.monitor.lastIpcObject.x;
        const monitorY = root.monitor.lastIpcObject.y;
        
        let bestWin = null;

        for (let i = 0; i < root.windows.length; i++) {
            const win = root.windows[i];
            if (!win.lastIpcObject) continue;

            const wx = win.lastIpcObject.at[0] - monitorX;
            const wy = win.lastIpcObject.at[1] - monitorY;
            const ww = win.lastIpcObject.size[0];
            const wh = win.lastIpcObject.size[1];

            if (mx >= wx && mx <= wx + ww && my >= wy && my <= wy + wh) {
                if (!bestWin) {
                    bestWin = win;
                } else {
                    const bestIpc = bestWin.lastIpcObject;
                    const currIpc = win.lastIpcObject;
                    
                    // Priority 1: Floating windows are on top of tiled windows
                    if (currIpc.floating && !bestIpc.floating) {
                        bestWin = win;
                    } else if (currIpc.floating === bestIpc.floating) {
                        // Priority 2: Most recently focused windows (smaller focusHistoryID) are on top
                        if (currIpc.focusHistoryID < bestIpc.focusHistoryID) {
                            bestWin = win;
                        }
                    }
                }
            }
        }

        if (bestWin) {
            const bestIpc = bestWin.lastIpcObject;
            selectionX = bestIpc.at[0] - monitorX;
            selectionY = bestIpc.at[1] - monitorY;
            selectionWidth = bestIpc.size[0];
            selectionHeight = bestIpc.size[1];
        } else {
            selectionX = 0;
            selectionY = 0;
            selectionWidth = 0;
            selectionHeight = 0;
        }
    }

    Behavior on selectionX { enabled: root.animateSelection; SpringAnimation { spring: 4; damping: 0.4 } }
    Behavior on selectionY { enabled: root.animateSelection; SpringAnimation { spring: 4; damping: 0.4 } }
    Behavior on selectionHeight { enabled: root.animateSelection; SpringAnimation { spring: 4; damping: 0.4 } }
    Behavior on selectionWidth { enabled: root.animateSelection; SpringAnimation { spring: 4; damping: 0.4 } }  
      

    ShaderEffect {  
        anchors.fill: parent  
        z: 0  
          
        property vector4d selectionRect: Qt.vector4d(  
            root.selectionX,  
            root.selectionY,  
            root.selectionWidth,  
            root.selectionHeight  
        )  
        property real dimOpacity: root.dimOpacity  
        property vector2d screenSize: Qt.vector2d(root.width, root.height)  
        property real borderRadius: root.borderRadius  
        property real outlineThickness: root.outlineThickness  
          
        fragmentShader: root.fragmentShader  
    }  

    MouseArea {  
        id: mouseArea  
        anchors.fill: parent  
        z: 3
        hoverEnabled: true
          
        onPositionChanged: (mouse) => { 
            root.mouseX = mouse.x;
            root.mouseY = mouse.y;
        }  
          
        onReleased: (mouse) => {  
            if (root.selectionWidth > 0 && root.selectionHeight > 0 &&
                mouse.x >= root.selectionX && mouse.x <= root.selectionX + root.selectionWidth &&
                mouse.y >= root.selectionY && mouse.y <= root.selectionY + root.selectionHeight) {
                root.regionSelected(  
                    Math.round(root.selectionX),  
                    Math.round(root.selectionY),  
                    Math.round(root.selectionWidth),  
                    Math.round(root.selectionHeight)  
                )  
            }
        }  
    }  
}