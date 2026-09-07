import QtQuick
import Quickshell.Services.Notifications

// Historial en memoria compartido por todas las islas/monitores.
QtObject {
    id: root

    required property var server
    property alias model: entries

    property ListModel entriesObject: ListModel { id: entries }
    signal notificationArrived(var entry)

    // Mantener la conexión como propiedad evita que QtObject la recoja.
    property var serverConnections: Connections {
        target: root.server
        ignoreUnknownSignals: true

        function onNotification(notification) {
            if (!notification || notification.lastGeneration)
                return

            // Mantener viva la notificación mientras aparece en el centro.
            notification.tracked = true

            function imageSource(value) {
                if (!value)
                    return ""
                const source = String(value)
                if (!source.length)
                    return ""
                if (source.startsWith("/") || source.startsWith("file://")
                        || source.startsWith("image://"))
                    return source
                return "image://icon/" + source
            }

            const entry = {
                "notificationId": notification.id,
                "appName": notification.appName || "Sistema",
                "summary": notification.summary || "Notificación",
                "body": notification.body || "",
                "image": imageSource(notification.image)
                         || imageSource(notification.appIcon),
                "urgency": notification.urgency,
                "time": Qt.formatTime(new Date(), "HH:mm"),
                "notificationRef": notification
            }
            entries.insert(0, entry)
            root.notificationArrived(entry)

            if (entries.count > 50)
                root.remove(entries.count - 1)
        }
    }

    function remove(index) {
        if (index < 0 || index >= entries.count)
            return
        const entry = entries.get(index)
        const notification = entry ? entry.notificationRef : null
        entries.remove(index)
        if (notification) {
            try {
                notification.expire()
            } catch (error) {
                console.warn("NotificationHistory: notification already gone", error)
            }
        }
    }

    function clear() {
        const liveNotifications = []
        for (let index = 0; index < entries.count; ++index) {
            const entry = entries.get(index)
            if (entry && entry.notificationRef)
                liveNotifications.push(entry.notificationRef)
        }
        entries.clear()
        for (let index = 0; index < liveNotifications.length; ++index) {
            try {
                liveNotifications[index].expire()
            } catch (error) {
                // La aplicación puede haber retirado la notificación primero.
            }
        }
    }
}
