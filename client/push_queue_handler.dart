import 'dart:async';
import 'dart:html';
import 'client_store.dart';
import 'twotier/wtypes.dart';
import 'rpc_lib.dart';
import 'lib/html_lib.dart';
import 'root/globals.dart';
import 'pane_factory.dart';
import 'twotier/wlib.dart';
import 'pane/base_pane.dart';
import 'pane/notify_pane.dart';

///message type used in PushQueueHandler
/*class _InterWindowMessage {
  String action; //'R' to remove or 'A' to add (light), or 'F' to add (full poll)
  List<PushQueueItem> items; //list of items to add/remove
}*/

///handles the my-stuff pane and calling the server periodically to update
/// the push queues
class PushQueueHandler {

  static Timer _suppressQuickRefreshTimer; //set while refresh button is invisible for 30s following a poll

  //one-time initializer
  static void init() {

    //set up receiver from other windows
    ClientStore.registerReceiveMessage(_receiveFromOtherWindow);

    //call first time fairly soon
    new Timer(new Duration(seconds:1), _timerTick);
  }

  //do timer work, and requeue the timer
  static Future _timerTick() async {
    //determine if we should poll now
    DateTime now = WLib.utcNow(),
      fifteenSecAgo = now.subtract(new Duration(seconds:15)),
      threeMinAgo = now.subtract(new Duration(minutes:3)),
      manyMinAgo = now.subtract(new Duration(minutes:25));
    bool pollNow = false;
    if (Globals.pollExplicitlyRequested && Globals.lastPollUtc.isBefore(fifteenSecAgo)) pollNow = true;
    if (Globals.pushQueue.length == 0 && Globals.lastPollUtc.isBefore(threeMinAgo)
      && Globals.lastActivityUtc.isAfter(manyMinAgo)) pollNow = true;

    if (pollNow && Globals.nick != null) {
      //UI while polling
      Globals.pollExplicitlyRequested = false;
      _showHideRefreshButton(false);

      //full mode?
      bool fullMode = now.subtract(new Duration(minutes:15)).isAfter(Globals.lastFullPollUtc);
      Globals.lastPollUtc = now;

      //call server
      PushQueueGetRequest pushArgs = new PushQueueGetRequest()
        ..depth = fullMode ? 'F' : 'L';
      Map rawResponse = await RpcLib.rpcAsMap('PushQueueGet', pushArgs);
      if (fullMode && rawResponse['fullModeStatus'] == null)
        Globals.lastFullPollUtc = now; //only updating the poll time if it was allowed by server
      List<PushQueueItem> items = _parseListOfRawItems(rawResponse['items']);
      itemsReceived(fullMode, items, 'S');

      //UI when done polling
      _showHideRefreshButton(true);
    }
    new Timer(new Duration(seconds:15), _timerTick);
  }

  ///show or hide refresh button; this encapsulates delay logic
  /// with a technique for cancelation, so that the user doesn't
  /// press refresh too often
  static void _showHideRefreshButton(bool show) {
    if (show) { //show refresh (delayed), hide working
      HtmlLib.showViaStyle('#refresh-working', false);
      _suppressQuickRefreshTimer = new Timer(new Duration(seconds:30), () {
        HtmlLib.showViaStyle('#button-refresh', true);
        _suppressQuickRefreshTimer = null;
      });
    } else { //hide refresh, show working
      if (_suppressQuickRefreshTimer != null) {
        _suppressQuickRefreshTimer.cancel();
        _suppressQuickRefreshTimer = null;
      }
      HtmlLib.showViaStyle('#button-refresh', false);
      HtmlLib.showViaStyle('#refresh-working', true);
    }
  }

  ///given raw items (as provided by JSON parsing), put these into
  /// nice class instances; also filter out notifications which are already open
  static List<PushQueueItem> _parseListOfRawItems(List<Map> rawitems) {
    if (rawitems == null) return new List();
    List<PushQueueItem> niceitems = rawitems.map((i){
      PushQueueItem qi = new PushQueueItem();
      APIDeserializer.deserialize(i, qi, null);
      return qi;
    }).toList();

    //filter out notifs that are already open
    niceitems.removeWhere((n) => Globals.panes.any((p) => p is NotifyPane && p.paneKey.part1 == n.sid));
    return niceitems;
  }

  ///entry point for receiving message from other window. This will be
  /// a Map as parsed by JSON, so we need to copy it into a real class
  static void _receiveFromOtherWindow(dynamic obj) {
    String action = obj['action'];
    List<Map> rawitems = obj['items'];
    List<PushQueueItem> items = _parseListOfRawItems(rawitems);
    if (action == 'A') itemsReceived(false, items, 'W');
    if (action == 'F') itemsReceived(true, items, 'W');
    if (action == 'R') for (PushQueueItem item in items) _removeItem(item, false);
  }

  ///send a list of queue items to other windows (to add or remove);
  /// each message is a Map containing
  ///   String action: 'R' to remove or 'A' to add (light), or 'F' to add (full poll)
  ///   List<PushQueueItem> items: list of items to add/remove
  static void sendToOtherWindows(String action, List<PushQueueItem> items) {
    if (items == null || items.length == 0) return;
    List<Map> itemsAsMaps = items.map((i) => {
      'sid': i.sid,
      'iid': i.iid,
      'kind': i.kind,
      'why': i.why,
      'text': i.text,
      'linkText': i.linkText,
      'linkPaneKey': i.linkPaneKey
      }).toList();
    var m = {'action': action, 'items': itemsAsMaps};
    ClientStore.sendMessage(m);
  }

  ///add items to screen and propagate to other windows
  /// source is B=business logic, S=server, W=another window
  static void itemsReceived(bool fullPoll, List<PushQueueItem> items, String source) {
    //rebuild queue
    if (source != 'B') {
      //note that business-logic items never cause clearing of any other item
      if (fullPoll) {
        Globals.pushQueue.clear();
      } else { // light poll
        Globals.pushQueue.removeWhere((i) => i.kind != 'S'); //keep suggestions intact
      }
    }
    Globals.pushQueue.addAll(items);

    //screen
    _rebuildMyStuff();

    //propagate
    Globals.lastPollUtc = WLib.utcNow();
    if (fullPoll) Globals.lastFullPollUtc = Globals.lastPollUtc;
    if (source != 'W') sendToOtherWindows(fullPoll ? 'F' : 'A', items);
  }

  ///remove item from screen and propagate to other windows
  /// (equality is based only on linkPaneKey);
  /// dont use for NotifyPane
  static void _removeItem(PushQueueItem item, bool fromLocal) {
    //remove from queue
    Globals.pushQueue.removeWhere((i) => i.kind != 'N' && i.linkPaneKey == item.linkPaneKey);
    _finishRemoveItem(item, fromLocal);
  }

  ///remove item from screen and propagate to other windows
  /// (equality is based only on sid);
  /// use for NotifyPane
  static void _removeNotifyItem(PushQueueItem item, bool fromLocal) {
    //remove from queue
    Globals.pushQueue.removeWhere((i) => i.kind == 'N' && i.sid == item.sid);
    _finishRemoveItem(item, fromLocal);
  }

  ///see _remove* methods
  static void _finishRemoveItem(PushQueueItem item, bool fromLocal) {
    if (Globals.pushQueue.length == 0) Globals.pollExplicitlyRequested = true;

    //screen
    _rebuildMyStuff();

    //propagate
    if (fromLocal) sendToOtherWindows('R', [item]);
  }

  ///rebuild my-stuff panel
  static void _rebuildMyStuff() {
    Element section;

    //get html for the img tag for an item
    String iconHtml(PushQueueItem i) {
      String iconName = '';
      if (i.kind == 'N') iconName = 'panenotify'; //notify
      else if (i.kind == 'U') iconName = 'paneconv'; //unread
      else if (i.why == 'V') iconName = 'paneproposal'; //why=vote
      else if (i.why == 'I') iconName = 'paneconv_invite'; //why=invited
      else if (i.why == 'R') iconName = 'paneconv_maybe'; //why=recommended
      else if (i.why == 'B') iconName = 'paneconv_star'; //why=bookmarked
      if (iconName.length == 0) return '';
      return '<img src="images/${iconName}.png" />';
    }

    //function to build one section
    void build1(String title, String kind) {
      StringBuffer s = new StringBuffer();
      s.write('<h2>${title}</h2>');
      List<PushQueueItem> items = Globals.pushQueue.where((i) => i.kind == kind).toList();
      for (PushQueueItem item in items) {
        s.write('<div>${iconHtml(item)} ');
        if (kind == 'N') { //notification: link to the notify pane
          String text = item.text ?? 'notification';
          if (text.length > 40) text = text.substring(0, 38) + '...';
          s.write('<a href="#notify/${item.sid}">${text}</a>');
        }
        else //link to the suggested pane
          s.write('<a href="#${item.linkPaneKey}">${item.linkText}</a>');
        s.write('</div>');
      }
      if (items.length == 0) s.write('(none)');
      section.innerHtml = s.toString();
    }
    section = querySelector('#queue-notify');
    build1('Notifications', 'N');
    section = querySelector('#queue-unread');
    build1('Unread', 'U');
    section = querySelector('#queue-suggest');
    build1('Suggestions', 'S');
    updateNextButton();
  }

  ///update the number showing in the 'Next' button
  static void updateNextButton() {
    //Next button
    String num = '';
    if (Globals.pushQueue.length > 0) num = Globals.pushQueue.length.toString();
    querySelector('#button-next-number').text = num;

    //browser title
    String titlePrefix = num.length > 0 ? '(' + num + ') ' : '';
    document.head.title = titlePrefix + Globals.appTitle;
  }

  ///show next item in push queue
  static void showNext() {
    List<PushQueueItem> q = Globals.pushQueue;
    if (q.length == 0) return;

    //get "first" item (which has to be in screen order, even if the queue
    // isn't)
    PushQueueItem item = q.firstWhere((i) => i.kind == 'N',
      orElse: () => q.firstWhere((j) => j.kind == 'U',
      orElse: () => q.first));

    //open it
    if (item.kind == 'N')
      PaneFactory.createFromString('notify/${item.sid}');
    else
      PaneFactory.createFromString(item.linkPaneKey);

    //note that when it actually opens, the pane should call notifyPaneOpened
  }

  ///notify this class that a pane was opened; this removes it from the queue
  static void notifyPaneOpened(BasePane p) {
    //make partial item (only the linkPaneKey matters since it is being removed)
    PushQueueItem item = new PushQueueItem() ..linkPaneKey = p.paneKey.full;
    if (p is NotifyPane) {
      item.sid = p.paneKey.full.substring(7); //omit 'notify/'
      _removeNotifyItem(item, true);
    } else {
      _removeItem(item, true);
    }
  }

  ///handler for refresh button
  static void refreshClicked() {
    _showHideRefreshButton(false);
    Globals.pollExplicitlyRequested = true;
  }

}