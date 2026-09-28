import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The clock's calendar popup: a month grid with ISO week numbers, built to
// sit beside the weather panel — same hero-over-detail composition, same
// spacing scale, same small-caps labels.
//
// The grid is a read-out rather than a picker: today is the only marked
// day, and the only thing that moves is which month is on screen —
// chevrons, the scroll wheel, and the arrow keys all step it.
//
// BarWidget.qml owns the bar label and hands this panel the button to
// anchor against.
Panel {
  id: root
  moduleName: "omarchy.clock"
  ipcTarget: "omarchy.clock"
  manageIpc: false

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel. Everything the bar identifies a panel by has to be that
  // widget: the popout coordinator (and with it the open-panel dot under the
  // pill) compares against `slot.activeItem`, and switchPanelFrom looks the
  // slot up the same way.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Today. SystemClock keeps this honest across midnight so the
  //      highlight rolls over without the panel being reopened.
  property date today: new Date()
  readonly property string todayKey: Model.keyForDate(today)

  // The month on screen. Stepping moves this and nothing else: the grid is
  // a read-out, not a picker, so there is no per-day cursor to keep in sync.
  property int viewYear: today.getFullYear()
  property int viewMonth: today.getMonth()
  property real monthWheelAccumulator: 0
  property string selectedDayKey: todayKey
  property var calendarAccounts: []
  property var calendarEvents: []
  property var calendarErrors: []
  property bool loadingEvents: false
  property bool savingAccount: false
  property bool savingEvent: false
  property bool managingAccounts: false
  property bool accountFormOpen: false
  property bool eventFormOpen: false
  property bool editAllDay: false
  property bool confirmDeleteEvent: false
  property string confirmDeleteAccountId: ""
  property string editingAccountId: ""
  property string eventAccountId: ""
  property var editingEvent: null
  property string calendarMessage: ""
  property int nextBackendId: 0
  property var backendQueue: []
  readonly property var selectedDayEvents: calendarEvents.filter(function(event) {
    return event.days && event.days.indexOf(root.selectedDayKey) !== -1
  })
  readonly property string backendPath: decodeURIComponent(String(Qt.resolvedUrl("calendar-backend")).replace(/^file:\/\//, ""))

  readonly property date viewDate: new Date(viewYear, viewMonth, 1)
  readonly property bool viewingCurrentMonth: viewYear === today.getFullYear() && viewMonth === today.getMonth()

  // Pinned to today, not to the month being browsed — stepping through the
  // calendar does not change how much of the year is gone.
  readonly property real yearDone: Model.yearProgress(today.getFullYear(), today.getMonth(), today.getDate())
  readonly property int yearDonePercent: Model.yearProgressPercent(today.getFullYear(), today.getMonth(), today.getDate())

  // Memento mori, for anyone who goes looking: double-tapping the year bar
  // asks for a birth year and a life expectancy, and a second bar tracks one
  // against the other. A birth year rather than an age, so it keeps counting
  // on its own. Without one the bar stays hidden.
  readonly property int birthYear: Model.parseBirthYear(setting("birthYear", 0), today.getFullYear())
  readonly property int age: Model.ageFromBirthYear(birthYear, today.getFullYear())
  readonly property int lifeExpectancy: Model.parseLifeExpectancy(setting("lifeExpectancy", 0))
  readonly property real lifeDone: Model.lifeProgress(age, lifeExpectancy)
  readonly property int lifeDonePercent: Model.lifeProgressPercent(age, lifeExpectancy)
  property bool editingLife: false

  // Unset falls through to the locale's own first day, so a fresh install
  // starts out matching the rest of the desktop rather than a hardcoded
  // convention. Clicking the grid's "W" heading writes the choice back to
  // shell.json.
  readonly property int weekStart: Model.normalizedWeekStart(setting("weekStartDay", null), Qt.locale().firstDayOfWeek)
  // The interface is English throughout, so day names are not taken from the
  // system locale. Where the week starts still is: that is a regional
  // convention rather than a translation, and it stays overridable above.
  readonly property var labelLocale: Qt.locale("en_US")
  readonly property string nextWeekStartLabel: labelLocale.dayName(Model.toggledWeekStart(weekStart), Locale.LongFormat)
  readonly property var weekdays: Model.weekdayOrder(weekStart)
  readonly property var weeks: Model.monthGrid(viewYear, viewMonth, weekStart, todayKey)


  // Guarded so the widget renders before the bar is injected (the bar-widget
  // contract instantiates it bare).
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int cellWidth: Style.space(52)
  readonly property int cellHeight: Style.space(34)
  readonly property int cellSpacing: Style.space(2)
  readonly property int weekColumnWidth: Style.space(32)
  readonly property int gutterWidth: Style.space(14)

  function open() {
    refresh()
    root.controller.show()
    sendBackend("accounts", {})
    // Set after showing, not before: showing hands the popout coordinator
    // over, which closes whichever panel was open, and that close clears the
    // shared flag. Deferring means the panel taking over always wins, while
    // a handoff to a panel that does not manage the flag still leaves it
    // cleared rather than stuck on.
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    // Outside clicks close this popup, including clicks made to copy a
    // CalDAV URL or app password from another window. Keep form drafts until
    // the user explicitly cancels, saves, or switches away from the form.
    if (root.editingLife) root.cancelEditingLife()
    root.confirmDeleteEvent = false
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // Summoning by hotkey moves no pointer, so a hover the bar was still
  // holding must not keep the center indicators revealed behind the panel.
  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function refresh() {
    root.today = new Date()
    root.goToToday()
  }

  function goToToday() {
    root.viewYear = today.getFullYear()
    root.viewMonth = today.getMonth()
    root.selectedDayKey = root.todayKey
    eventRefreshTimer.restart()
  }

  function moveMonth(delta) {
    var next = Model.stepMonth(viewYear, viewMonth, delta)
    root.viewYear = next.year
    root.viewMonth = next.month
    root.selectedDayKey = root.viewingCurrentMonth ? root.todayKey : Model.dateKey(next.year, next.month, 1)
    eventRefreshTimer.restart()
  }

  function selectDay(day) {
    root.viewYear = day.year
    root.viewMonth = day.month
    root.selectedDayKey = day.key
    eventRefreshTimer.restart()
  }

  function eventCountForDay(key) {
    var count = 0
    for (var i = 0; i < root.calendarEvents.length; i++)
      if (root.calendarEvents[i].days && root.calendarEvents[i].days.indexOf(key) !== -1) count++
    return count
  }

  function eventTimeLabel(event) {
    if (event.allDay) return "Ganztägig"
    return event.start.slice(11, 16) + "–" + event.end.slice(11, 16)
  }

  function sendBackend(operation, data) {
    var request = { id: ++root.nextBackendId, operation: operation, data: data }
    if (backendProcess.running) backendProcess.write(JSON.stringify(request) + "\n")
    else {
      root.backendQueue = root.backendQueue.concat([request])
      backendProcess.running = true
    }
  }

  function loadEvents() {
    if (root.calendarAccounts.length === 0) {
      root.calendarEvents = []
      root.calendarErrors = []
      root.loadingEvents = false
      return
    }
    root.loadingEvents = true
    sendBackend("events", { year: root.viewYear, month: root.viewMonth + 1 })
  }

  function handleBackendLine(line) {
    var reply
    try { reply = JSON.parse(line) }
    catch (error) { root.calendarMessage = "Der Kalenderdienst hat ungültige Daten geliefert."; return }
    if (!reply.ok) {
      root.calendarMessage = reply.error || "Kalenderanfrage fehlgeschlagen."
      root.loadingEvents = false
      root.savingAccount = false
      root.savingEvent = false
      return
    }
    var data = reply.data || {}
    root.calendarMessage = ""
    switch (reply.operation) {
    case "accounts":
      root.calendarAccounts = data.accounts || []
      eventRefreshTimer.restart()
      break
    case "events":
      if (data.year !== root.viewYear || data.month !== root.viewMonth + 1) {
        eventRefreshTimer.restart()
        break
      }
      root.calendarEvents = data.events || []
      root.calendarErrors = data.errors || []
      root.loadingEvents = false
      break
    case "save_account":
      root.savingAccount = false
      root.accountFormOpen = false
      accountPasswordField.text = ""
      sendBackend("accounts", {})
      break
    case "remove_account":
      root.confirmDeleteAccountId = ""
      sendBackend("accounts", {})
      break
    case "event":
      root.editingEvent = data
      root.eventAccountId = data.accountId
      root.editAllDay = data.allDay
      eventTitleField.text = data.title || ""
      eventLocationField.text = data.location || ""
      eventDescriptionField.text = data.description || ""
      eventStartDateField.text = data.start.slice(0, 10)
      eventEndDateField.text = data.allDay ? Model.keyForDate(new Date(new Date(data.end.slice(0, 10) + "T12:00:00").getTime() - 86400000)) : data.end.slice(0, 10)
      eventStartTimeField.text = data.allDay ? "09:00" : data.start.slice(11, 16)
      eventEndTimeField.text = data.allDay ? "10:00" : data.end.slice(11, 16)
      root.eventFormOpen = true
      break
    case "save_event":
    case "delete_event":
      root.savingEvent = false
      root.eventFormOpen = false
      root.confirmDeleteEvent = false
      root.editingEvent = null
      eventRefreshTimer.restart()
      break
    }
  }

  function startNewAccount() {
    root.managingAccounts = true
    root.accountFormOpen = true
    root.editingAccountId = ""
    accountNameField.text = ""
    accountUsernameField.text = ""
    accountUrlField.text = ""
    accountPasswordField.text = ""
  }

  function editAccount(account) {
    root.managingAccounts = true
    root.accountFormOpen = true
    root.editingAccountId = account.id
    accountNameField.text = account.name
    accountUsernameField.text = account.username
    accountUrlField.text = account.url
    accountPasswordField.text = ""
  }

  function saveAccount() {
    root.savingAccount = true
    sendBackend("save_account", {
      accountId: root.editingAccountId,
      name: accountNameField.text,
      username: accountUsernameField.text,
      url: accountUrlField.text,
      password: accountPasswordField.text
    })
  }

  function startNewEvent() {
    if (root.calendarAccounts.length === 0) { root.managingAccounts = true; return }
    root.managingAccounts = false
    root.editingEvent = null
    root.eventAccountId = root.calendarAccounts[0].id
    root.editAllDay = false
    root.confirmDeleteEvent = false
    eventTitleField.text = ""
    eventLocationField.text = ""
    eventDescriptionField.text = ""
    eventStartDateField.text = root.selectedDayKey
    eventEndDateField.text = root.selectedDayKey
    eventStartTimeField.text = "09:00"
    eventEndTimeField.text = "10:00"
    root.eventFormOpen = true
  }

  function editExistingEvent(event) {
    root.calendarMessage = ""
    sendBackend("event", { accountId: event.accountId, resourceUrl: event.resourceUrl })
  }

  function saveCalendarEvent() {
    root.savingEvent = true
    sendBackend("save_event", {
      accountId: root.eventAccountId,
      resourceUrl: root.editingEvent ? root.editingEvent.resourceUrl : "",
      etag: root.editingEvent ? root.editingEvent.etag : "",
      title: eventTitleField.text,
      location: eventLocationField.text,
      description: eventDescriptionField.text,
      allDay: root.editAllDay,
      start: eventStartDateField.text + (root.editAllDay ? "" : "T" + eventStartTimeField.text),
      end: eventEndDateField.text + (root.editAllDay ? "" : "T" + eventEndTimeField.text)
    })
  }

  function deleteCalendarEvent() {
    if (!root.editingEvent) return
    root.savingEvent = true
    sendBackend("delete_event", {
      accountId: root.editingEvent.accountId,
      resourceUrl: root.editingEvent.resourceUrl,
      etag: root.editingEvent.etag
    })
  }

  function moveYear(delta) {
    moveMonth(delta * 12)
  }

  // Applied locally first so the panel redraws on the click itself; the
  // shell.json write comes back through the bar as the same value. With no
  // writable entry (the widget is not in the layout) it stays a session-only
  // preference rather than doing nothing. The host widget builds its own
  // entry when the label format is cycled, so it has to be kept in step or
  // it would write this key straight back out from a stale copy.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function setWeekStart(day) {
    var next = Model.normalizedWeekStart(day, root.weekStart)
    if (next === root.weekStart) return
    persistSettings({ weekStartDay: Model.weekStartSettingName(next) })
  }

  function startEditingLife() {
    root.editingLife = true
    Qt.callLater(function() {
      bornField.text = root.birthYear > 0 ? String(root.birthYear) : ""
      expectancyField.text = String(root.lifeExpectancy)
      bornField.selectAll()
      bornField.forceActiveFocus()
    })
  }

  function cancelEditingLife() {
    root.editingLife = false
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  // Shared by both fields: Tab hops to the other one, Enter commits the pair,
  // Escape drops the lot.
  function handleLifeKey(event, other) {
    if (event.key === Qt.Key_Escape) {
      root.cancelEditingLife()
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.commitLife()
      event.accepted = true
    } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      other.selectAll()
      other.forceActiveFocus()
      event.accepted = true
    }
  }

  // Double-tapping the life bar puts it away again. The expectancy stays in
  // the config so setting a birth year again brings your own number back
  // rather than the default.
  function clearLife() {
    if (root.birthYear <= 0) return
    persistSettings({ birthYear: 0 })
  }

  function commitLife() {
    var born = Model.parseBirthYear(bornField.text, today.getFullYear())
    var span = Model.parseLifeExpectancy(expectancyField.text)
    if (born !== root.birthYear || span !== root.lifeExpectancy)
      persistSettings({ birthYear: born, lifeExpectancy: span })
    cancelEditingLife()
  }

  function toggleWeekStart() {
    setWeekStart(Model.toggledWeekStart(root.weekStart))
  }

  // English short day names, matching the rest of the interface.
  function weekdayLabel(weekday) {
    return String(labelLocale.dayName(weekday, Locale.ShortFormat)).toUpperCase()
  }

  Timer {
    id: eventRefreshTimer
    interval: 100
    repeat: false
    onTriggered: root.loadEvents()
  }

  Timer {
    interval: 300000
    repeat: true
    running: root.opened && root.calendarAccounts.length > 0
    onTriggered: root.loadEvents()
  }

  Process {
    id: backendProcess
    command: [root.backendPath]
    stdinEnabled: true
    running: true
    onStarted: {
      var queued = root.backendQueue
      root.backendQueue = []
      for (var i = 0; i < queued.length; i++)
        backendProcess.write(JSON.stringify(queued[i]) + "\n")
      root.sendBackend("accounts", {})
    }
    onExited: {
      root.calendarMessage = "Der Kalenderdienst wurde beendet."
      backendRestartTimer.restart()
    }
    stdout: SplitParser {
      onRead: function(line) { root.handleBackendLine(line) }
    }
  }

  Timer {
    id: backendRestartTimer
    interval: 2000
    repeat: false
    onTriggered: backendProcess.running = true
  }

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: {
      if (Model.keyForDate(clock.date) === String(root.todayKey)) return
      var followToday = root.viewingCurrentMonth
      root.today = clock.date
      if (followToday) root.goToToday()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(calendarColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingLife || root.accountFormOpen || root.eventFormOpen
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.moveMonth(dx)
        if (dy !== 0) root.moveYear(dy)
      }
      onActivateRequested: root.goToToday()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "[") root.moveMonth(-1)
        else if (t === "]") root.moveMonth(1)
        else if (t === "{") root.moveYear(-1)
        else if (t === "}") root.moveYear(1)
        else if (t === "t" || t === "T") root.goToToday()
        else if (t === "w" || t === "W") root.toggleWeekStart()
      }

      Flickable {
        id: calendarScroll
        anchors.fill: parent
        contentWidth: calendarColumn.width
        contentHeight: calendarColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height || contentWidth > width

        Column {
          id: calendarColumn
          // Never narrower than the grid. The popup width is capped to what
          // the screen allows, and a fixed seven-column grid would otherwise
          // lose its last days off the edge instead of scrolling.
          width: Math.max(calendarScroll.width, gridColumn.width)
          spacing: Style.space(8)

          // ---- Hero: today, centered. Once the view has stepped back
          //      it is also the way home — clicking the date you are
          //      looking for beats hunting for a reset button.
          Item {
            width: parent.width
            height: heroRow.height

            Row {
              id: heroRow
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(22)

              Text {
                // Baseline-aligned, not center-aligned: "July 26" carries a
                // descender, so centering the two boxes leaves the icon
                // sitting visibly low against the digits.
                anchors.baseline: heroDate.baseline
                text: "󰃭"
                color: heroMouse.containsMouse
                  ? Style.hoverStateColor(root.contentForeground, Color.accent)
                  : root.contentForeground
                font.family: root.contentFontFamily
                // Decorative, and deliberately outside the Style.font.*
                // scale. Sized so the glyph reads at the cap height of the
                // date beside it rather than towering over it.
                font.pixelSize: 48
              }

              Text {
                id: heroDate
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: Qt.formatDate(root.today, "MMMM d")
                color: heroMouse.containsMouse
                  ? Style.hoverStateColor(root.contentForeground, Color.accent)
                  : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: 52
                font.bold: true
              }
            }

            MouseArea {
              id: heroMouse
              x: heroRow.x
              y: heroRow.y
              width: heroRow.width
              height: heroRow.height
              enabled: !root.viewingCurrentMonth
              hoverEnabled: enabled
              cursorShape: Qt.PointingHandCursor
              onClicked: root.goToToday()

              PanelToolTip {
                visible: heroMouse.containsMouse
                text: "Back to today"
                fontFamily: root.contentFontFamily
              }
            }
          }

          // ---- Year progress, doubling as the rule under the hero:
          //      a plain hairline said nothing, and whole days done
          //      over days in the year says the same thing louder.
          Item {
            width: parent.width
            height: yearBlock.y + yearBlock.height

            Item {
              id: yearBlock
              y: Style.space(6)
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: Math.max(yearLabel.implicitHeight, Style.space(10))

              TapHandler {
                enabled: !root.editingLife
                onDoubleTapped: root.startEditingLife()
              }

              Row {
                visible: root.editingLife
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(10)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "BORN"
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }

                TextField {
                  id: bornField
                  width: Style.space(70)
                  anchors.verticalCenter: parent.verticalCenter
                  placeholderText: "year"
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  inputMethodHints: Qt.ImhDigitsOnly

                  Keys.onPressed: function(event) { root.handleLifeKey(event, expectancyField) }
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.verticalCenterOffset: 0
                  leftPadding: Style.space(6)
                  text: "LIVE TO"
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }

                TextField {
                  id: expectancyField
                  width: Style.space(60)
                  anchors.verticalCenter: parent.verticalCenter
                  placeholderText: "90"
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  inputMethodHints: Qt.ImhDigitsOnly

                  Keys.onPressed: function(event) { root.handleLifeKey(event, bornField) }
                }
              }

              Text {
                id: yearLabel
                textFormat: Text.PlainText
                visible: !root.editingLife
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: root.today.getFullYear()
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }

              Text {
                id: yearPercent
                textFormat: Text.PlainText
                visible: !root.editingLife
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.yearDonePercent + "%"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Rectangle {
                id: yearTrack
                visible: !root.editingLife
                anchors.left: yearLabel.right
                anchors.right: yearPercent.left
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(6)
                radius: Style.cornerRadius > 0 ? height / 2 : 0
                color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)

                Rectangle {
                  width: Math.round(parent.width * root.yearDone)
                  height: parent.height
                  radius: parent.radius
                  color: Style.selectedStateColor(root.contentForeground, Color.accent)

                  Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                }
              }
            }
          }

          // ---- Memento mori. Only here once someone has gone looking and
          //      given an age; the same rail as the year above it, measured
          //      against a nominal lifetime.
          Item {
            visible: root.birthYear > 0
            width: parent.width
            height: visible ? lifeBlock.height : 0

            Item {
              id: lifeBlock
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: Math.max(lifeLabel.implicitHeight, Style.space(10))

              Text {
                id: lifeLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "LIFE"
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }

              Text {
                id: lifePercent
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.lifeDonePercent + "%"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Rectangle {
                anchors.left: lifeLabel.right
                anchors.right: lifePercent.left
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(6)
                radius: Style.cornerRadius > 0 ? height / 2 : 0
                color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)

                Rectangle {
                  width: Math.round(parent.width * root.lifeDone)
                  height: parent.height
                  radius: parent.radius
                  color: Style.selectedStateColor(root.contentForeground, Color.accent)

                  Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                }
              }

              TapHandler {
                onDoubleTapped: root.clearLife()
              }

              MouseArea {
                id: lifeMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton

                PanelToolTip {
                  visible: lifeMouse.containsMouse
                  text: "Memento Mori"
                  fontFamily: root.contentFontFamily
                }
              }
            }
          }

          // ---- Month grid: week numbers down a gutter on the left, then
          //      the seven day columns. Always six rows, so the popup is
          //      exactly as tall in February as it is in August.
          Item {
            width: parent.width
            height: gridColumn.y + gridColumn.height

            WheelHandler {
              acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
              blocking: true
              onWheel: function(event) {
                // A mouse notch is 120 angle units. Touchpads often send
                // smaller increments, so wait for a full step before moving.
                var delta = event.angleDelta.y
                if (delta === 0 && event.pixelDelta.y !== 0) delta = event.pixelDelta.y * 2
                if (delta === 0) { event.accepted = false; return }
                var wheel = Util.wheelSteps(root.monthWheelAccumulator, delta)
                root.monthWheelAccumulator = wheel.remainder
                if (wheel.steps !== 0) root.moveMonth(-wheel.steps)
              }
            }

            Column {
              id: gridColumn
              // The meter above is a solid rule; the grid needs room to
              // read as its own block rather than hanging off it.
              y: Style.space(18)
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(3)

              Row {
                id: headerRow
                spacing: root.cellSpacing

                // The week-number heading doubles as the week-start toggle.
                // It is the one control in the panel whose meaning is not
                // self-evident, so it carries a tooltip naming the day the
                // click will switch to.
                Rectangle {
                  width: root.weekColumnWidth
                  height: Style.space(16)
                  radius: Style.cornerRadius
                  color: weekStartMouse.containsMouse
                    ? Style.hoverFillFor(root.contentForeground, Color.accent)
                    : "transparent"

                  Text {
                    anchors.centerIn: parent
                    text: "W"
                    color: weekStartMouse.containsMouse
                      ? Style.hoverStateColor(root.contentForeground, Color.accent)
                      : Qt.darker(root.contentForeground, 1.9)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                    font.bold: true
                  }

                  MouseArea {
                    id: weekStartMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleWeekStart()
                  }

                  PanelToolTip {
                    visible: weekStartMouse.containsMouse
                    text: "Start weeks on " + root.nextWeekStartLabel
                    fontFamily: root.contentFontFamily
                  }
                }

                Item {
                  width: root.gutterWidth
                  height: Style.space(16)
                }

                Repeater {
                  model: root.weekdays

                  Text {
                    textFormat: Text.PlainText
                    required property var modelData
                    width: root.cellWidth
                    height: Style.space(16)
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: root.weekdayLabel(modelData)
                    color: Qt.darker(root.contentForeground, 1.5)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                    font.bold: true
                  }
                }
              }

              Repeater {
                model: root.weeks

                Row {
                  required property var modelData
                  spacing: root.cellSpacing

                  Text {
                    textFormat: Text.PlainText
                    width: root.weekColumnWidth
                    height: root.cellHeight
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: modelData.week
                    color: Qt.darker(root.contentForeground, 1.9)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Item {
                    width: root.gutterWidth
                    height: root.cellHeight
                  }

                  Repeater {
                    model: modelData.days

                    Rectangle {
                      required property var modelData
                      readonly property int eventCount: root.eventCountForDay(modelData.key)

                      width: root.cellWidth
                      height: root.cellHeight
                      radius: Style.cornerRadius
                      color: root.selectedDayKey === modelData.key
                        ? Style.hoverFillFor(root.contentForeground, Color.accent) : "transparent"
                      border.width: modelData.today || root.selectedDayKey === modelData.key ? Style.spacing.hairline : 0
                      border.color: Style.normalBorderFor(root.contentForeground, Color.accent)

                      Text {
                        textFormat: Text.PlainText
                        anchors.centerIn: parent
                        text: modelData.day
                        color: modelData.inMonth
                          ? (modelData.weekend ? Qt.darker(root.contentForeground, 1.45) : root.contentForeground)
                          : Qt.darker(root.contentForeground, 2.2)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.body
                        font.bold: modelData.today
                      }

                      Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: Style.space(3)
                        width: Math.min(Style.space(16), Style.space(4) * parent.eventCount)
                        height: Style.space(3)
                        radius: height / 2
                        visible: parent.eventCount > 0
                        color: Color.accent
                      }

                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.selectDay(parent.modelData)
                      }
                    }
                  }
                }
              }
            }

            // Hairline down the week-number gutter, drawn only beside the
            // day rows so it does not cut through the header band.
            Rectangle {
              x: gridColumn.x + root.weekColumnWidth + root.cellSpacing + Math.round((root.gutterWidth - width) / 2)
              y: gridColumn.y + headerRow.height + gridColumn.spacing
              width: Style.spacing.hairline
              height: gridColumn.height - headerRow.height - gridColumn.spacing
              color: root.contentForeground
              opacity: 0.1
            }
          }

          // ---- Month stepping, spanning the grid it drives. The chevrons
          //      sit on the grid's outer bounds, the same edges the year
          //      rail above uses, so the row reads as the panel's other
          //      full-width rail instead of a cluster floating in space.
          //      The label is centered and fixed-width, so it holds still
          //      from "MAY" to "SEPTEMBER".
          Item {
            width: parent.width
            height: monthNav.height

            Item {
              id: monthNav
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: monthLabel.implicitHeight + Style.space(10)

              Text {
                id: monthLabel
                textFormat: Text.PlainText
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                // Fixed width so the chevrons hold still between a
                // "MAY 2026" and a "SEPTEMBER 2026".
                width: Style.space(130)
                horizontalAlignment: Text.AlignHCenter
                text: Qt.formatDate(root.viewDate, "MMMM yyyy").toUpperCase()
                color: Qt.darker(root.contentForeground, 1.4)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                font.letterSpacing: 1
              }

              PanelActionButton {
                // Pulled out by the button's own padding so the glyph, not
                // its hit box, lines up with the "2026" on the year rail.
                anchors.left: parent.left
                anchors.leftMargin: -Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅁"
                tooltipText: "Previous month"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.moveMonth(-1)
              }

              PanelActionButton {
                anchors.right: parent.right
                anchors.rightMargin: -Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅂"
                tooltipText: "Next month"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.moveMonth(1)
              }
            }
          }

          Rectangle {
            width: parent.width - Style.space(36)
            anchors.horizontalCenter: parent.horizontalCenter
            height: Style.spacing.hairline
            color: root.contentForeground
            opacity: 0.18
          }

          Column {
            id: agendaArea
            width: parent.width - Style.space(36)
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(9)

            Item {
              width: parent.width
              height: Math.max(heading.implicitHeight, accountToggle.height)

              Text {
                id: heading
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.managingAccounts ? "KONTEN & KALENDER" : "TERMINE"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                font.letterSpacing: 1
              }

              CalendarButton {
                id: accountToggle
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                label: root.managingAccounts ? "Zu Terminen" : "Konten"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: {
                  root.managingAccounts = !root.managingAccounts
                  root.accountFormOpen = false
                  accountPasswordField.text = ""
                }
              }

              CalendarButton {
                anchors.right: accountToggle.left
                anchors.rightMargin: Style.space(7)
                anchors.verticalCenter: parent.verticalCenter
                visible: !root.managingAccounts && root.calendarAccounts.length > 0
                label: "Aktualisieren"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.loadEvents()
              }
            }

            Text {
              width: parent.width
              visible: root.calendarMessage !== ""
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              text: root.calendarMessage
              color: Color.urgent
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Repeater {
              model: root.calendarErrors
              Text {
                required property var modelData
                width: agendaArea.width
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                text: modelData.name + ": " + modelData.message
                color: Color.urgent
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            Column {
              visible: root.managingAccounts
              width: parent.width
              spacing: Style.space(8)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                text: "Für jeden Nextcloud-Kalender die persönliche CalDAV-Adresse aus der Kalender-App eintragen."
                color: Qt.darker(root.contentForeground, 1.4)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Repeater {
                model: root.calendarAccounts
                Column {
                  required property var modelData
                  width: agendaArea.width
                  spacing: Style.space(5)

                  Item {
                    width: parent.width
                    height: Style.space(39)

                    Column {
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter
                      width: parent.width - editAccountButton.width - removeAccountButton.width - Style.space(22)
                      Text {
                        width: parent.width
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        text: modelData.name
                        color: root.contentForeground
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.body
                        font.bold: true
                      }
                      Text {
                        width: parent.width
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        text: modelData.username
                        color: Qt.darker(root.contentForeground, 1.5)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }

                    CalendarButton {
                      id: removeAccountButton
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      label: "Entfernen"
                      danger: true
                      foreground: root.contentForeground
                      fontFamily: root.contentFontFamily
                      onClicked: root.confirmDeleteAccountId = modelData.id
                    }
                    CalendarButton {
                      id: editAccountButton
                      anchors.right: removeAccountButton.left
                      anchors.rightMargin: Style.space(7)
                      anchors.verticalCenter: parent.verticalCenter
                      label: "Bearbeiten"
                      foreground: root.contentForeground
                      fontFamily: root.contentFontFamily
                      onClicked: root.editAccount(modelData)
                    }
                  }

                  Row {
                    visible: root.confirmDeleteAccountId === modelData.id
                    spacing: Style.space(7)
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: "Konto lokal entfernen?"
                      color: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                    CalendarButton {
                      label: "Ja"
                      danger: true
                      foreground: root.contentForeground
                      onClicked: root.sendBackend("remove_account", { accountId: modelData.id })
                    }
                    CalendarButton {
                      label: "Abbrechen"
                      foreground: root.contentForeground
                      onClicked: root.confirmDeleteAccountId = ""
                    }
                  }
                }
              }

              CalendarButton {
                visible: !root.accountFormOpen
                label: "Kalender hinzufügen"
                primary: true
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.startNewAccount()
              }

              Column {
                visible: root.accountFormOpen
                width: parent.width
                spacing: Style.space(6)

                Text {
                  text: root.editingAccountId ? "KALENDER BEARBEITEN" : "KALENDER VERBINDEN"
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }
                TextField {
                  id: accountNameField
                  width: parent.width
                  placeholderText: "Name, z. B. Privat"
                  foreground: root.contentForeground
                }
                TextField {
                  id: accountUsernameField
                  width: parent.width
                  placeholderText: "Nextcloud-Benutzername"
                  foreground: root.contentForeground
                }
                TextField {
                  id: accountUrlField
                  width: parent.width
                  placeholderText: "https://…/caldav/…"
                  foreground: root.contentForeground
                  inputMethodHints: Qt.ImhUrlCharactersOnly
                }
                TextField {
                  id: accountPasswordField
                  width: parent.width
                  placeholderText: root.editingAccountId ? "Neues App-Passwort (leer: bisheriges behalten)" : "Nextcloud-App-Passwort"
                  foreground: root.contentForeground
                  password: true
                }
                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  wrapMode: Text.Wrap
                  text: "Das App-Passwort wird im lokalen Schlüsselbund gespeichert. Du kannst zum Kopieren das Fenster wechseln; nach erneutem Klick auf die Uhr bleiben deine Eingaben erhalten."
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
                Row {
                  spacing: Style.space(7)
                  CalendarButton {
                    label: root.savingAccount ? "Verbinde…" : "Speichern & prüfen"
                    primary: true
                    enabled: !root.savingAccount
                    foreground: root.contentForeground
                    onClicked: root.saveAccount()
                  }
                  CalendarButton {
                    label: "Abbrechen"
                    foreground: root.contentForeground
                    onClicked: { root.accountFormOpen = false; accountPasswordField.text = "" }
                  }
                }
              }
            }

            Column {
              visible: !root.managingAccounts
              width: parent.width
              spacing: Style.space(8)

              Item {
                width: parent.width
                height: Math.max(selectedDateLabel.implicitHeight, newEventButton.height)
                Text {
                  id: selectedDateLabel
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: Qt.formatDate(new Date(root.selectedDayKey + "T12:00:00"), "dddd, d. MMMM yyyy")
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
                CalendarButton {
                  id: newEventButton
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  label: "Neuer Termin"
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  enabled: root.calendarAccounts.length > 0
                  onClicked: root.startNewEvent()
                }
              }

              Text {
                visible: root.calendarAccounts.length === 0
                width: parent.width
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                text: "Verbinde zuerst einen Nextcloud-Kalender über Konten."
                color: Qt.darker(root.contentForeground, 1.4)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                visible: root.loadingEvents && root.calendarAccounts.length > 0
                text: "Termine werden geladen…"
                color: Qt.darker(root.contentForeground, 1.4)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Column {
                visible: !root.eventFormOpen
                width: parent.width
                spacing: Style.space(5)

                Repeater {
                  model: root.selectedDayEvents
                  Rectangle {
                    required property var modelData
                    width: agendaArea.width
                    height: Style.space(46)
                    radius: Style.cornerRadius
                    color: eventMouse.containsMouse
                      ? Style.hoverFillFor(root.contentForeground, Color.accent)
                      : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.055)

                    Rectangle {
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(7)
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(3)
                      height: parent.height - Style.space(12)
                      radius: width / 2
                      color: Color.accent
                    }

                    Column {
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(18)
                      anchors.right: parent.right
                      anchors.rightMargin: Style.space(8)
                      anchors.verticalCenter: parent.verticalCenter
                      Text {
                        width: parent.width
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        text: modelData.title
                        color: root.contentForeground
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.body
                        font.bold: true
                      }
                      Text {
                        width: parent.width
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        text: root.eventTimeLabel(modelData) + " · " + modelData.accountName + (modelData.recurring ? " · Serie" : "")
                        color: Qt.darker(root.contentForeground, 1.5)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }

                    MouseArea {
                      id: eventMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.editExistingEvent(parent.modelData)
                    }
                  }
                }

                Text {
                  visible: !root.loadingEvents && root.calendarAccounts.length > 0 && root.selectedDayEvents.length === 0
                  text: "Keine Termine an diesem Tag."
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }

              Column {
                visible: root.eventFormOpen
                width: parent.width
                spacing: Style.space(6)

                Text {
                  text: root.editingEvent ? "TERMIN BEARBEITEN" : "TERMIN ERSTELLEN"
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }
                Text {
                  visible: root.editingEvent && root.editingEvent.recurring
                  width: parent.width
                  textFormat: Text.PlainText
                  wrapMode: Text.Wrap
                  text: "Serientermin: Änderungen gelten für die gesamte Serie."
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Row {
                  spacing: Style.space(6)
                  Repeater {
                    model: root.calendarAccounts
                    CalendarButton {
                      required property var modelData
                      label: modelData.name
                      selected: root.eventAccountId === modelData.id
                      enabled: !root.editingEvent
                      foreground: root.contentForeground
                      onClicked: root.eventAccountId = modelData.id
                    }
                  }
                }

                TextField {
                  id: eventTitleField
                  width: parent.width
                  placeholderText: "Titel"
                  foreground: root.contentForeground
                }

                CalendarButton {
                  label: root.editAllDay ? "Ganztägig: Ja" : "Ganztägig: Nein"
                  selected: root.editAllDay
                  foreground: root.contentForeground
                  onClicked: root.editAllDay = !root.editAllDay
                }

                Row {
                  spacing: Style.space(7)
                  TextField {
                    id: eventStartDateField
                    width: Style.space(160)
                    placeholderText: "Beginn: JJJJ-MM-TT"
                    foreground: root.contentForeground
                  }
                  TextField {
                    id: eventStartTimeField
                    visible: !root.editAllDay
                    width: Style.space(90)
                    placeholderText: "HH:MM"
                    foreground: root.contentForeground
                  }
                }
                Row {
                  spacing: Style.space(7)
                  TextField {
                    id: eventEndDateField
                    width: Style.space(160)
                    placeholderText: "Ende: JJJJ-MM-TT"
                    foreground: root.contentForeground
                  }
                  TextField {
                    id: eventEndTimeField
                    visible: !root.editAllDay
                    width: Style.space(90)
                    placeholderText: "HH:MM"
                    foreground: root.contentForeground
                  }
                }
                Text {
                  visible: root.editAllDay
                  text: "Enddatum einschließlich"
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
                TextField {
                  id: eventLocationField
                  width: parent.width
                  placeholderText: "Ort (optional)"
                  foreground: root.contentForeground
                }
                Rectangle {
                  width: parent.width
                  height: Style.space(74)
                  radius: Style.cornerRadius
                  color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.055)
                  border.width: Style.spacing.hairline
                  border.color: Style.normalBorderFor(root.contentForeground, Color.accent)

                  QQC.TextArea {
                    id: eventDescriptionField
                    anchors.fill: parent
                    anchors.margins: Style.space(5)
                    placeholderText: "Beschreibung (optional)"
                    wrapMode: TextEdit.Wrap
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    background: null
                  }
                }

                Row {
                  spacing: Style.space(7)
                  CalendarButton {
                    label: root.savingEvent ? "Speichere…" : "Speichern"
                    primary: true
                    enabled: !root.savingEvent
                    foreground: root.contentForeground
                    onClicked: root.saveCalendarEvent()
                  }
                  CalendarButton {
                    label: "Abbrechen"
                    foreground: root.contentForeground
                    onClicked: { root.eventFormOpen = false; root.confirmDeleteEvent = false }
                  }
                  CalendarButton {
                    visible: !!root.editingEvent
                    label: "Löschen"
                    danger: true
                    foreground: root.contentForeground
                    onClicked: root.confirmDeleteEvent = true
                  }
                }
                Row {
                  visible: root.confirmDeleteEvent
                  spacing: Style.space(7)
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.editingEvent && root.editingEvent.recurring ? "Ganze Serie löschen?" : "Termin löschen?"
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                  CalendarButton {
                    label: "Ja, löschen"
                    danger: true
                    enabled: !root.savingEvent
                    foreground: root.contentForeground
                    onClicked: root.deleteCalendarEvent()
                  }
                  CalendarButton {
                    label: "Nein"
                    foreground: root.contentForeground
                    onClicked: root.confirmDeleteEvent = false
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
